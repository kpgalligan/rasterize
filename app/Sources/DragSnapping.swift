import AppKit

/// Where the ONE snapping engine (`SnapEngine.swift`) meets every drag in
/// the app. This file is the phase's completeness audit: EVERY canvas
/// gesture has a row below, including the ones that must not snap.
///
/// | Drag | Snaps | Call site |
/// |---|---|---|
/// | Move layer / multi-selection | total delta, whole px | `moveDidUpdate` |
/// | Move arrow nudge | no ¹ | `moveNudge` |
/// | Free Transform · move | quad's bounding box | `snapTransform` |
/// | Free Transform · scale handle | restricted ² | `snapTransform` |
/// | Free Transform · distort corner | exact ³ | `snapTransform` |
/// | Free Transform · rotate | no ⁴ | — |
/// | Crop box · handle / draw | the POINT, whole px ⁵ ¹⁵ | `snapCropPoint` |
/// | Crop box · move | delta, press-time box | `snapCropDelta` |
/// | Shape drag (rect / ellipse / line) | after the ⇧ constraint ¹⁵ | `ShapeToolPreview` |
/// | Shape re-edit (handle / move) | restricted ² ⁶ | `snapShapeEditPoint` |
/// | Rect marquee | whole px, ONE helper, latched ⁷ ¹⁵ | `snappedMarqueeRect` |
/// | Ellipse marquee | exact, same helper, latched ¹⁵ | `snappedMarqueeRect` |
/// | Lasso vertex | each click | `mouseDown`, `.lasso` |
/// | Guide drag | one axis, whole px ⁸ | `guideMouseDragged` |
/// | Paint strokes (6 tools) | no ⁹ | — |
/// | Text placement click | no ¹⁰ | — |
/// | Gradient endpoints | no ¹¹ | — |
/// | Patch region | no ¹² | — |
/// | Red Eye rect | no ¹³ | — |
/// | Clone / heal source | no ¹⁴ | — |
/// | Zoom marquee / scrubby, hand, eyedropper, subject | never | — |
///
/// 1. An arrow key is an explicit N-pixel request.
/// 2. Only the axes `handle.unit` can drive, and only on a box that is not
///    rotated, not warped and not ⇧-constrained — see the handle rule below.
/// 3. `distorting` pulls the point back through the inverted matrix.
/// 4. ⇧ already snaps rotation to 15° (`LayerTransform.rotating`).
/// 5. Ahead of `resizing`, never `session.rect` after it — see ORDERING.
/// 6. In CANVAS space, before the inverse map: guides are canvas objects.
/// 7. One helper builds the rect, on every tick, and the tick's answer is
///    LATCHED (`marqueePreview`) for the commit to use, so what lands is
///    what was previewed — rather than re-derived at mouse-up, which would
///    read the release event's ⌃ flag instead of the last tick's.
/// 8. Excluding every guide PARALLEL to the dragged one, not merely the
///    dragged one: see `guideSnapEngine`.
/// 9. A stroke is freehand, and pulling a dab to a guide would break the
///    spacing engine's arc length — a gap or a blot at the guide.
/// 10. It is a click, not a drag: the insertion point is placed by the
///    layout, and snapping it would move a baseline nobody aimed at.
/// 11. An endpoint has no edge to align; the missing ⇧-45° constraint is a
///    separate gap, not this phase's.
/// 12. It already snaps to whole pixels on purpose (`PatchSession`), and
///    guides are not what it is placed against.
/// 13. A tight box around a pupil has nothing to do with guides.
/// 14. See finding 2 below.
/// 15. BOTH corners of every rubber band snap — the crop box, the shape
///    drag and the two marquees — and the FIXED one is snapped on every
///    tick rather than once at mouse-down. Suspension is why: ⌃ is read per
///    tick, so a corner snapped once at the press could not be released for
///    the rest of the gesture (the marquees did exactly that, and holding ⌃
///    mid-drag freed the moving corner while the anchor stayed pinned to
///    whatever it had landed on). The anchor does not move, so its own pull
///    answers the same on every tick — the same result a mouse-down snap
///    gives, minus the blind spot. It costs one extra `pull` per tick.
///
/// THREE FINDINGS RECORDED RATHER THAN SILENTLY OMITTED.
///
/// 1. **"Moving a selection" is not in this phase, because the gesture does
///    not exist.** Pressing inside a marquee starts a NEW one, there is no
///    Select ▸ Transform Selection, and no agent tool translates a
///    selection. Building it is a feature, not a snap site.
/// 2. **The clone / heal source's fractional offset is a known, deliberate
///    omission.** `cloneOffset` is fractional, so `context.draw` resamples
///    the snapshot on every dab — the one place in the app where being
///    fractional is an active defect, and exactly the argument
///    `PatchSession` already makes for the patch. Fixing it means snapping
///    to the PIXEL GRID, not to guides, and this phase adds no
///    "snap to pixels" target: the drags that need whole pixels already
///    round (Move, the rect marquee, the patch offset) and the crop rounds
///    at commit.
/// 3. **The canvas's own engine is ASKED FOR at mouse-down, not pushed.**
///    `canvas.snapEngine` — what the marquees, the lasso and the shape drag
///    read — was originally pushed by a sync from `syncCanvasPaintState()`,
///    which follows a tool switch, an options-bar edit and every View-menu
///    toggle but not an edit: a guide dragged out of a ruler without leaving
///    the marquee tool was not a target for the next marquee. Rebuilding in
///    `imageDidChange` would have been the wrong fix — that runs the content
///    fold after every settled edit, the 0.12 s below, paid per brush
///    stroke. So the canvas calls `onSnapEngine` at the mouse-down of the
///    six tools in `snappingCanvasTools` and holds the answer for the press.
///
/// WHAT A HANDLE MAY SNAP, AND WHAT IT MAY NOT. `LayerTransform.scaling`
/// solves in the box's OWN axes, and three of its properties make "snap the
/// world point and re-solve" wrong in general: an EDGE handle has zero span
/// on the other axis and simply cannot move there; under ⇧ one factor drives
/// both axes, so a corner traces a LINE, not a plane; and `clampScale` can
/// silently absorb the result. An engine that reports a hit and draws a line
/// the handle then does not land on is worse than no snap. So: offer X
/// candidates only when `handle.unit.x != 0`, Y only when
/// `handle.unit.y != 0`, and skip handle snapping ENTIRELY when
/// `session.transform.angle != 0`, when the box has corner offsets, or when
/// ⇧ is held. `shapeEditMouseDragged` gets the identical treatment: it pulls
/// the canvas point through `session.transform.inverted()` and then applies
/// `CropSession.resizing` in LOCAL space, so a world-space snap on a
/// non-identity placement has the same failure.
///
/// Both handle paths then VERIFY: they re-solve, ask where the handle
/// actually landed, and keep the unsnapped transform when it did not reach
/// the line (within half a SCREEN point — what matters is whether a person
/// can see the handle miss). The gating above rules out the reachability
/// failures that are knowable in advance; the check rules out the rest,
/// which is what `clampScale` and `distorting`'s convexity refusal can do
/// after the fact.
///
/// ORDERING. Where a drag re-derives a dependent axis the order is
/// **snap → re-derive → clamp**, and only the DRIVING axis snaps. The crop
/// box gets that for free by snapping the POINT before the switch rather
/// than `session.rect` after it: `resizing` takes a point plus a handle
/// index and cannot be re-run from a rect, and a rect snapped after
/// `resizing`/`clamped` would break the very aspect ratio the rule protects.
///
/// BUILT ONCE PER GESTURE, NEVER PER TICK — and what that actually pins
/// down is the CONTENT-BOUNDS FOLD. The fold behind the `.layers` target is
/// a per-pixel sweep per leaf, and `moveDidUpdate` posts
/// `.imageDocumentImageDidChange` on EVERY mouse-moved event, so a fold
/// rebuilt "on document change" would sweep the whole stack per drag tick.
/// (`AgentServer+Groups.contentBoxes` records the number that forced its own
/// bottom-up fold: `get_document` went from 0.12 s to 1.10 s on a
/// 3000 × 2000 document with 41 layers once 9 nested groups made each group
/// re-walk its children.) Two gestures hold their whole engine, because they
/// have somewhere to put it: the canvas's own point drags read
/// `canvas.snapEngine`, filled once at their mouse-down from
/// `onSnapEngine`, and a guide drag holds its own in
/// `GuideDragSession.snap`. The crop box, the shape re-edit
/// and the Free Transform have no stored property to hold one — their
/// sessions live in files this item does not own — so they ask
/// `makeSnapEngine(for:)` per tick, which is safe for exactly the reason the
/// rule exists: the fold is CACHED on the controller (`snapBoxes`) and
/// re-folded only when the document SETTLES, and everything else the build
/// does is a handful of struct reads and a few dozen `SnapLine`s. The Move
/// drag is the one gesture that edits the document while it runs, which is
/// why `foldedSnapBoxes` reuses that cache across a LIVE change instead of
/// keying strictly on the handle.
///
/// A GESTURE IS NEVER ITS OWN SNAP TARGET, and that is a property of the
/// engine — decided by the `DragKind` it is built for, never patched up
/// afterwards by the drag: `setSelection` fires on every marquee drag tick,
/// so a marquee would stick to its own previous edge; a Move would snap to
/// the box it is dragging; a guide drag's `.guides` lines still contain the
/// guide being dragged, so it would spring back and could not be nudged by
/// less than the pull radius; and a shape RE-EDIT's layer is still visible in
/// the document (the session hides it in the canvas's preview alone), so it
/// is dropped from `.layers` for the same reason.
enum DragKind {
    /// The marquees, the lasso and the shape drag — gestures whose geometry
    /// lives in the canvas and which snap a POINT.
    case canvasPoint
    case move
    case transform
    case crop
    case shape
    case guide
}

extension EditorViewController {
    // MARK: - Building the engine

    /// The engine one gesture snaps against: the candidate lines, the static
    /// boxes Smart Guides measure spacing between, the grid's step and the
    /// canvas. `kind` decides which subject is dropped, because a gesture is
    /// never its own snap target (see the header for where each gesture's
    /// value lives and why a per-tick build is not a per-tick sweep).
    func makeSnapEngine(for kind: DragKind) -> SnapEngine {
        let store = ToolOptionsStore.shared
        guard store.view.snapEnabled, let doc = document?.doc else { return .inactive }
        var targets = SnapTarget(rawValue: store.view.snapTargets)
        // The two options-bar checkboxes narrow ONE target each, and only
        // for their own gesture. View ▸ Snap outranks both, which is why it
        // is the guard above rather than a third `remove`: a checkbox can
        // take a target away, never give snapping back where the menu turned
        // it off.
        if kind == .crop, !store.crop.snapToGuides { targets.remove(.guides) }
        if kind == .move, !store.move.snapToLayers { targets.remove(.layers) }
        guard !targets.isEmpty else { return .inactive }

        let chrome = canvas.chrome
        let canvasSize = doc.canvasSize
        var lines: [SnapLine] = []
        var layerRects: [CGRect] = []

        if targets.contains(.guides), chrome.guidesVisible {
            // Hidden guides neither hit-test nor snap: a line you cannot see
            // must not move your drag. The guide being DRAGGED is dropped
            // too — left in its own target list it pulls the drag straight
            // back to where it started, and the guide cannot be nudged by
            // less than the pull radius. (A guide drag then drops every
            // PARALLEL guide as well, in `guideSnapEngine`, which is where
            // the reason belongs: that is about what the core will store,
            // not about what a gesture may snap to.)
            let dragged = kind == .guide ? (canvas.guideDrag?.guideID ?? 0) : 0
            for guide in canvas.guides where guide.id != dragged {
                lines.append(guide.snapLine)
            }
        }
        if targets.contains(.layers) {
            let excluded = snapExclusion(for: kind, doc)
            for (index, box) in foldedSnapBoxes(doc).enumerated() where !excluded.contains(index) {
                guard let box = box, box.width > 0, box.height > 0 else { continue }
                layerRects.append(box)
                lines += SnapEngine.lines(of: box, kind: .layer)
            }
        }
        // `setSelection` fires on every marquee drag tick, so a marquee whose
        // own selection were a target would stick to its own previous edge.
        if targets.contains(.selection), !selectionIsSubject(of: kind),
           let bounds = canvas.selection?.bounds {
            lines += SnapEngine.lines(of: bounds, kind: .selection)
        }
        if targets.contains(.documentBounds) {
            lines += SnapEngine.documentLines(canvas: canvasSize)
        }
        // The grid snaps only while it is DRAWN, by the same rule guides
        // follow: a line nobody can see must not move a drag. That is asked
        // of the canvas itself (`drawsDocumentGrid`, the very predicate the
        // drawing gates on) rather than restated from `chrome.showGrid`
        // alone — restated, it missed the crop straighten's stand-down and
        // the crop box snapped to lines that had left the screen. Anchored
        // at canvas (0, 0) inside the engine — never at the ruler origin,
        // which moves labels alone — so the grid that is snapped to and the
        // grid that is drawn are one grid.
        let gridOn = targets.contains(.grid) && canvas.drawsDocumentGrid
        return SnapEngine(
            lines: lines, layerRects: layerRects,
            gridStepX: gridOn ? chrome.gridStepX : nil,
            gridStepY: gridOn ? chrome.gridStepY : nil,
            // BOTH ladders, because the engine chooses between them per zoom:
            // the subdivisions are what `drawDocumentGrid` paints as the fine
            // lines and the spacing what it paints as the heavy ones, and a
            // zoom at which the fine ones are too close to aim at leaves the
            // heavy ones perfectly aimable (`SnapEngine.gridStep`).
            gridMajorX: gridOn ? chrome.gridMajorX : nil,
            gridMajorY: gridOn ? chrome.gridMajorY : nil,
            canvasSize: canvasSize, isEnabled: true)
    }

    /// The entries whose boxes this gesture must NOT snap to: the ones it is
    /// moving, plus their enclosing groups, whose folded box contains them
    /// and therefore moves with them.
    private func snapExclusion(for kind: DragKind, _ doc: RasterDocument) -> Set<Int> {
        let moving: [Int]
        switch kind {
        case .move:
            moving = doc.movingSet(document?.selectedLayerIndices ?? [])
        case .transform:
            // The session's own list is already the expanded set, so a
            // transform pays nothing to learn what it is moving.
            moving = transformSession?.layers ?? []
        case .shape:
            // The re-edited layer is still VISIBLE in `document.doc` —
            // `beginShapeEditSession` hides it only in the canvas's preview
            // image — so without this it contributes its own six lines and
            // pulls every handle and every interior drag straight back to
            // where the gesture started: a re-edited shape could not be
            // resized or nudged by less than the pull radius. Exactly the
            // spring-back the header calls out for the guide drag.
            moving = shapeEditSession.map { [$0.layer] } ?? []
        case .canvasPoint, .crop, .guide:
            return []
        }
        guard !moving.isEmpty else { return [] }
        let tree = doc.layerTree
        var excluded = Set(moving)
        for index in moving {
            excluded.formUnion(tree.ancestors(of: index))
        }
        return excluded
    }

    /// True when the gesture's own subject IS the selection, which is when
    /// the selection's bounds must not be a target.
    private func selectionIsSubject(of kind: DragKind) -> Bool {
        kind == .canvasPoint && Self.selectionTools.contains(currentTool)
    }

    /// The tools whose drags REWRITE the selection. A set rather than a
    /// switch: this is not mouse or key dispatch, so it wants no exhaustive
    /// arm per tool, and a new selection tool joins one list.
    private static let selectionTools: Set<EditorTool> = [
        .select, .ellipseSelect, .lasso, .wand, .subject,
    ]

    /// Every entry's CONTENT box in canvas coordinates, or nil where the
    /// entry contributes nothing visible — hidden, inside a hidden group, or
    /// holding no opaque pixel at all.
    ///
    /// The twin of `AgentServer+Groups.contentBoxes`, written here rather
    /// than called because this one answers in canvas rects and drops what
    /// the picture does not show; a THIRD copy must hoist both to a shared
    /// file. Its argument is quoted in this file's header: `layerBounds` on a
    /// GROUP re-walks every descendant with no memoization, and a group's
    /// children always sit BELOW it in the bottom-first stack, so ONE forward
    /// pass folds each group's box out of its children's — one sweep per
    /// LEAF and none per group. Union is associative, so the fold gives
    /// exactly what the core's descendant union gives.
    ///
    /// THE PER-PIXEL SCAN IS MEMOIZED IN THE CORE, on the pixel and mask
    /// `Arc` allocations plus the offset (`doc_group_query`'s foot), so a
    /// re-fold after an edit re-scans only the LAYERS THAT CHANGED. This
    /// cache alone was not enough and could not be: it is keyed on the
    /// document HANDLE, and every settled edit — a brush stroke, an undo, an
    /// agent call — mints a new one, so the first drag afterwards paid a
    /// full-stack sweep inside its own mouse-down (measured at 58 ms on a
    /// 3000 × 2000 document with 20 sparse canvas-sized layers, and linear in
    /// both count and area). A per-layer key cannot live on this side: the
    /// host has no cheap identity for a layer's pixels, and an address
    /// carried across the FFI could be reused by a later allocation. Where
    /// the memo does live, a `Weak` keeps the allocation alive and pointer
    /// equality is exact.
    ///
    /// CACHED on the controller, keyed on the handle it was measured from —
    /// and reused across a LIVE document change on purpose. `imageDidChange`
    /// clears the cache on every SETTLED change and deliberately keeps it
    /// through a live one, and the Move drag is why: it replaces the document
    /// HANDLE on every tick, so a strict identity test would re-fold per tick
    /// and put the per-pixel sweep back exactly where the cache exists to
    /// keep it out. Its live document differs from the base only in the
    /// layers it is moving, which the engine built for that gesture already
    /// excludes, so those ticks read the pre-drag boxes — which is what a
    /// drag should be measured against anyway.
    func foldedSnapBoxes(_ doc: RasterDocument) -> [CGRect?] {
        if let cached = snapBoxes, cached.boxes.count == doc.layerCount,
           cached.doc === doc || moveAppliedDelta != nil {
            return cached.boxes
        }
        let tree = doc.layerTree
        // `contributingEntries` is the host's ONE mirror of the core's
        // visibility predicate (own `visible`, and every enclosing group's):
        // a hidden entry has no box here, and neither has anything inside a
        // hidden group, so a folded group's union is exactly what the
        // projection shows.
        let contributing = Set(doc.contributingEntries())
        var boxes = [CGRect?](repeating: nil, count: tree.count)
        for index in 0..<tree.count where contributing.contains(index) {
            guard tree.isGroup(index) else {
                boxes[index] = doc.layerBounds(index).map {
                    CGRect(
                        x: CGFloat($0.x), y: CGFloat($0.y),
                        width: CGFloat($0.width), height: CGFloat($0.height))
                }
                continue
            }
            var union: CGRect?
            for child in tree.children(of: index) {
                guard let box = boxes[child] else { continue }
                union = union.map { $0.union(box) } ?? box
            }
            boxes[index] = union
        }
        snapBoxes = (doc, boxes)
        return boxes
    }

    /// The pointer state one tick contributes. ⌃ is read HERE, from the
    /// event's own flags, on every tick and never latched at mouse-down, so
    /// suspending mid-drag works — Photoshop's behaviour, and the reason the
    /// three closures that carry these drags were widened to pass them.
    func snapContext(_ modifiers: NSEvent.ModifierFlags) -> SnapContext {
        SnapContext(
            magnification: canvas.magnification, suspended: modifiers.contains(.control))
    }

    // MARK: - Smart Guides

    /// Pushes what a live Move or Free Transform drag earned into the canvas,
    /// redrawing only when the list actually changes state — a drag tick that
    /// had no smart guides and still has none must not schedule a repaint of
    /// its own.
    func pushSmartGuides(_ lines: [SmartGuideLine]) {
        if lines.isEmpty, canvas.smartGuides.isEmpty { return }
        canvas.smartGuides = lines
        canvas.needsDisplay = true
    }

    /// The static boxes a smart-guide solve runs against: the engine's own
    /// layer boxes — the gesture's subject already dropped — plus the canvas
    /// rect, so a box can align to the picture's edges and its centre lines
    /// as readily as to another layer. Capped at the nearest 64 by the
    /// solver, whose own doc says why.
    private func smartGuideStatics(_ engine: SnapEngine, moving: CGRect) -> [CGRect] {
        let canvasRect = CGRect(origin: .zero, size: engine.canvasSize)
        let statics = engine.layerRects + (canvasRect.isEmpty ? [] : [canvasRect])
        return SmartGuideSolver.nearest(statics, to: moving)
    }

    /// A quad's EXACT bounding box — `LayerTransform.exactBounds`, named here
    /// only to keep the call sites short.
    ///
    /// Deliberately NOT `LayerTransform.boundingExtent`, which rounds OUTWARD
    /// because it mirrors how the core sizes a destination buffer: a box
    /// snapped after that rounding would put the layer's real edge up to a
    /// pixel from the line it was pulled to, and the smart guide drawn beside
    /// it would sit at the rounded edge, which is not where the pixels are.
    private func boundingBox(of points: [CGPoint]) -> CGRect? {
        LayerTransform.exactBounds(of: points)
    }

    // MARK: - Move

    /// The Move drag's TOTAL delta, corrected — and the drag's smart guides,
    /// pushed from the SAME corrected box, so the lines drawn can only
    /// describe where the layers actually went.
    ///
    /// `.wholePixels`, with no post-hoc rounding: the candidates round before
    /// the distance test, so the set lands on a whole pixel AND on the line,
    /// while rounding afterwards would leave it half a pixel off the
    /// smart-guide line being drawn at the same moment. The press-time box is
    /// integral (`transformSourceRect` answers in whole pixels) and the delta
    /// is an integer, so the `Int` conversion below is exact rather than a
    /// second rounding — with one honest exception: an ODD-sized box's centre
    /// line sits on a half pixel and cannot land on a whole-pixel candidate,
    /// so that one pull is swallowed by the conversion. The drawings are
    /// computed from the CONVERTED total for exactly that reason, and so
    /// annotate only alignments that really happened.
    func snapMoveDelta(
        _ dx: Int, _ dy: Int, _ modifiers: NSEvent.ModifierFlags
    ) -> (Int, Int) {
        guard let pressBox = movePressBox else {
            pushSmartGuides([])
            return (dx, dy)
        }
        let engine = makeSnapEngine(for: .move)
        let context = snapContext(modifiers)
        let raw = pressBox.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy))
        let statics = smartGuideStatics(engine, moving: raw)
        // Equal spacing is the solver's ONLY candidate contribution: aligning
        // to a layer's edges and centres is already what `pull` does against
        // the `.layers` target, and two functions deriving one offset from
        // the same rects is how a box gets corrected twice.
        let spacing = SmartGuideSolver.spacingCandidates(moving: raw, statics: statics)
        let snapped = engine.snappedDelta(
            of: pressBox, by: CGVector(dx: CGFloat(dx), dy: CGFloat(dy)), in: context,
            quantize: .wholePixels, extra: spacing)
        let total = (Self.wholeDelta(snapped.dx, dx), Self.wholeDelta(snapped.dy, dy))
        // Nothing to annotate while snapping is off or suspended: the
        // alignment a drawing would claim is one the drag was not being
        // helped towards.
        guard engine.isEnabled, !context.suspended else {
            pushSmartGuides([])
            return total
        }
        let corrected = pressBox.offsetBy(dx: CGFloat(total.0), dy: CGFloat(total.1))
        pushSmartGuides(
            SmartGuideSolver.drawings(
                moving: corrected, statics: statics, canvas: engine.canvasSize))
        return total
    }

    /// A corrected delta back as the integer the Move op takes, falling back
    /// to the uncorrected one rather than converting anything a `CGFloat` →
    /// `Int` conversion would TRAP on. Nothing reachable produces a
    /// non-finite offset — the engine filters non-finite candidates and the
    /// delta arrives as an integer — but a crash is not the failure mode a
    /// snap may ever have.
    private static func wholeDelta(_ value: CGFloat, _ fallback: Int) -> Int {
        guard value.isFinite, abs(value) < CGFloat(Int32.max) else { return fallback }
        return Int(value.rounded())
    }

    // MARK: - Free Transform

    /// The ONE snap for all four Free Transform drag kinds, applied between
    /// the solver and the assignment.
    func snapTransform(
        _ transform: LayerTransform, drag: TransformDrag, session: TransformSession,
        modifiers: NSEvent.ModifierFlags
    ) -> LayerTransform {
        let engine = makeSnapEngine(for: .transform)
        let context = snapContext(modifiers)
        let corrected: LayerTransform
        switch drag {
        case let .move(start, _):
            corrected = snapTransformMove(
                transform, from: start, session: session, engine: engine, context: context,
                modifiers: modifiers)
        case let .scale(handle, start):
            corrected = snapTransformScale(
                transform, handle: handle, from: start, session: session, engine: engine,
                context: context, modifiers: modifiers)
        case let .distort(corner, start):
            corrected = snapTransformDistort(
                transform, corner: corner, from: start, session: session, engine: engine,
                context: context)
        case .rotate:
            // ⇧ already snaps rotation to 15°, and a rotating box has no edge
            // to align: nothing to correct, and nothing to annotate either.
            pushSmartGuides([])
            return transform
        }
        drawTransformSmartGuides(corrected, session: session, engine: engine, context: context)
        return corrected
    }

    /// The `.move` case: the warped quad's bounding box is snapped IN PLACE
    /// and the correction re-applied through `moving`, so the box's own
    /// parameters stay the source of truth. It is the one transform drag that
    /// TRANSLATES a whole box, so it is the one that offers the smart guides'
    /// equal-spacing candidates — the same contest, through `pull`'s `extra`,
    /// as the Move tool's.
    ///
    /// Under ⇧ the move is constrained to one axis, and only THAT axis may
    /// snap — a correction on the other one would break the constraint the
    /// user is holding. Which axis survived is read off the transform
    /// `moving` just produced rather than recomputed from the pointer, so the
    /// constraint's own tie-break lives in one place.
    private func snapTransformMove(
        _ transform: LayerTransform, from start: LayerTransform, session: TransformSession,
        engine: SnapEngine, context: SnapContext, modifiers: NSEvent.ModifierFlags
    ) -> LayerTransform {
        guard let box = boundingBox(of: transform.warpedQuad(of: session.sourceRect))
        else { return transform }
        var drivesX = true
        var drivesY = true
        if modifiers.contains(.shift) {
            // `moving` zeroes the smaller component and keeps X on a tie, so
            // an unchanged Y is exactly what "X drives" looks like from here
            // — including the tie itself, where neither moved because the
            // delta was zero.
            drivesY = transform.translation.dy != start.translation.dy
            drivesX = !drivesY
        }
        let spacing = SmartGuideSolver.spacingCandidates(
            moving: box, statics: smartGuideStatics(engine, moving: box))
        var correction = CGVector.zero
        // TAGGED coordinates, because `spacing` is in play: a spacing
        // candidate names the one edge it was computed for, and an untagged
        // triple would let it be applied to another (`SnapCoordinate`).
        if drivesX, let offset = engine.pull(
            SnapEngine.coordinates(of: box, axis: .vertical), axis: .vertical, in: context,
            quantize: .exact, extra: spacing)
        {
            correction.dx = offset
        }
        if drivesY, let offset = engine.pull(
            SnapEngine.coordinates(of: box, axis: .horizontal), axis: .horizontal,
            in: context, quantize: .exact, extra: spacing)
        {
            correction.dy = offset
        }
        guard correction.dx != 0 || correction.dy != 0 else { return transform }
        return LayerTransform.moving(transform, by: correction, constrained: false)
    }

    /// The `.scale` case, restricted per the header's handle rule and then
    /// verified: the world handle point snaps on the axes the handle can
    /// drive, `scaling` re-solves from the drag's own start, and the result
    /// is kept only if the handle really landed there.
    private func snapTransformScale(
        _ transform: LayerTransform, handle: TransformHandle, from start: LayerTransform,
        session: TransformSession, engine: SnapEngine, context: SnapContext,
        modifiers: NSEvent.ModifierFlags
    ) -> LayerTransform {
        // A rotated box solves in its own axes, a warped one moves its
        // handles through the corner offsets, and ⇧ couples both axes so a
        // corner traces a line: in all three the handle cannot reach an
        // arbitrary canvas point, and an engine that reported a hit would
        // draw a line the box never lands on.
        guard transform.angle == 0, !transform.hasCornerOffsets,
              !modifiers.contains(.shift)
        else { return transform }
        let world = transform.warpedHandlePoint(handle, of: session.sourceRect)
        let target = snappedHandlePoint(
            world, edges: SnapEdges.forTransformHandle(handle), engine: engine,
            context: context, quantize: .exact)
        guard target != world else { return transform }
        let candidate = LayerTransform.scaling(
            start, in: session.sourceRect, handle: handle, to: target,
            proportional: false, aboutPivot: modifiers.contains(.option))
        let landed = candidate.warpedHandlePoint(handle, of: session.sourceRect)
        guard candidate.isFinite, reached(landed, target, context) else { return transform }
        return candidate
    }

    /// The `.distort` case: exact, because `distorting` pulls the point back
    /// through the inverted affine. It still verifies, for the one thing the
    /// gating cannot know in advance — a corner that would fold the quad or
    /// blow the extent sticks at `start`, and the snapped point must not be
    /// allowed to turn a legal drag into that refusal.
    private func snapTransformDistort(
        _ transform: LayerTransform, corner: Int, from start: LayerTransform,
        session: TransformSession, engine: SnapEngine, context: SnapContext
    ) -> LayerTransform {
        let quad = transform.warpedQuad(of: session.sourceRect)
        guard quad.indices.contains(corner) else { return transform }
        let world = quad[corner]
        let target = snappedHandlePoint(
            world, edges: SnapEdges.forQuadCorner(corner), engine: engine, context: context,
            quantize: .exact)
        guard target != world else { return transform }
        let candidate = LayerTransform.distorting(
            start, corner: corner, to: target, in: session.sourceRect)
        let landed = candidate.warpedQuad(of: session.sourceRect)
        guard landed.indices.contains(corner), candidate.isFinite,
              reached(landed[corner], target, context)
        else { return transform }
        return candidate
    }

    /// One handle point, snapped only on the axes its `edges` say it owns.
    ///
    /// `.centerX` is what `SnapEdges.forTransformHandle` gives a handle whose
    /// `unit.x` is zero — an edge handle sitting ON the centre line, which
    /// cannot move along it — so the presence of a LEFT or RIGHT edge is
    /// exactly "this handle drives X". The crop's index space agrees
    /// (`forCropHandle` gives an edge handle its one edge and nothing else),
    /// which is what lets both handle paths share this function.
    func snappedHandlePoint(
        _ point: CGPoint, edges: SnapEdges, engine: SnapEngine, context: SnapContext,
        quantize: SnapQuantize
    ) -> CGPoint {
        var result = point
        if !edges.intersection([.left, .right]).isEmpty,
           let offset = engine.pull(
               [point.x], axis: .vertical, in: context, quantize: quantize) {
            result.x += offset
        }
        if !edges.intersection([.top, .bottom]).isEmpty,
           let offset = engine.pull(
               [point.y], axis: .horizontal, in: context, quantize: quantize) {
            result.y += offset
        }
        return result
    }

    /// Whether a re-solved handle actually arrived. Half a SCREEN point,
    /// because the question is whether a person can SEE the handle miss the
    /// line it was pulled to; in canvas units that is half a pixel at 100 %
    /// and a sixteenth at 800 %, which is where a miss would show.
    private func reached(_ landed: CGPoint, _ target: CGPoint, _ context: SnapContext) -> Bool {
        let tolerance = 0.5 / max(context.magnification, 0.001)
        return abs(landed.x - target.x) <= tolerance && abs(landed.y - target.y) <= tolerance
    }

    /// The transform box's smart guides, computed from the CORRECTED box —
    /// so, as with the Move drag, they can only annotate an alignment that
    /// actually happened. Every drag kind but `.rotate` earns them: a scale
    /// or a distort still lands edges and centres against other layers, and
    /// the solver emits a gap bar only where a gap is genuinely equal.
    private func drawTransformSmartGuides(
        _ transform: LayerTransform, session: TransformSession, engine: SnapEngine,
        context: SnapContext
    ) {
        guard engine.isEnabled, !context.suspended,
              let box = boundingBox(of: transform.warpedQuad(of: session.sourceRect))
        else {
            pushSmartGuides([])
            return
        }
        pushSmartGuides(
            SmartGuideSolver.drawings(
                moving: box, statics: smartGuideStatics(engine, moving: box),
                canvas: engine.canvasSize))
    }

    // MARK: - Crop

    /// The crop POINT snap — BEFORE `resizing`/`clamped`, never after.
    ///
    /// `.wholePixels`, because `commitCropSession` rounds each edge and says
    /// why, so a snap that landed on a half pixel would commit one pixel away
    /// from what the box showed. Only the axes the drag can drive are
    /// offered: a handle's own edges, and — when a RATIO is in force — only
    /// the axis that ratio leaves free, since `resizing` re-derives the other
    /// one and a snap there would be silently discarded.
    func snapCropPoint(
        _ point: CGPoint, drag: CropSession.Drag, modifiers: NSEvent.ModifierFlags
    ) -> CGPoint {
        let engine = makeSnapEngine(for: .crop)
        let context = snapContext(modifiers)
        let ratio = cropSession?.ratio
        var edges: SnapEdges
        switch drag {
        case let .handle(index, _):
            edges = SnapEdges.forCropHandle(index)
            // With a ratio, `resizing` keeps a corner's dragged WIDTH and
            // re-derives its height, so a corner drives X alone; the edge
            // handles already carry exactly the one edge they drive.
            if ratio != nil, !edges.intersection([.left, .right]).isEmpty {
                edges.subtract([.top, .bottom])
            }
        case .draw:
            // A rubber band drives both axes — unless a ratio re-derives the
            // height from the width, which is the same rule as a corner's.
            edges = ratio == nil ? .all : [.left, .right]
        case .move:
            // Its point is a grab OFFSET, not the moved geometry: the delta
            // form snaps that gesture, and this one leaves it alone.
            return point
        }
        return snappedHandlePoint(
            point, edges: edges, engine: engine, context: context, quantize: .wholePixels)
    }

    /// The crop `.move` case: its point is a grab OFFSET, not the moved
    /// geometry, so it snaps a delta against the press-time box. `clamped`
    /// still has the final word, exactly as it does without a snap.
    func snapCropDelta(
        from start: CGRect, by delta: CGVector, modifiers: NSEvent.ModifierFlags
    ) -> CGVector {
        let engine = makeSnapEngine(for: .crop)
        return engine.snappedDelta(
            of: start, by: delta, in: snapContext(modifiers), quantize: .wholePixels)
    }

    // MARK: - Shape re-edit

    /// The shape re-edit's canvas point, snapped before the inverse map —
    /// guides are canvas objects, and the local box is derived from the
    /// canvas point.
    ///
    /// A HANDLE snaps only under an identity placement, the header's rule:
    /// the point is pulled through `session.transform.inverted()` and then
    /// run through `CropSession.resizing` in LOCAL space, so on a rotated or
    /// scaled shape the canvas coordinate the engine chose is not a
    /// coordinate the local box can be given. A `.move` is a canvas-space
    /// translation under any map, so it always snaps — as the QUAD's bounding
    /// box, never the grab point, which sits wherever the press happened to
    /// land inside the shape.
    func snapShapeEditPoint(
        _ point: CGPoint, drag: ShapeEditSession.Drag, _ modifiers: NSEvent.ModifierFlags
    ) -> CGPoint {
        guard let session = shapeEditSession else { return point }
        let engine = makeSnapEngine(for: .shape)
        let context = snapContext(modifiers)
        switch drag {
        case let .handle(index, _):
            guard session.transform.isIdentity else { return point }
            return snappedHandlePoint(
                point, edges: SnapEdges.forCropHandle(index), engine: engine, context: context,
                quantize: .exact)
        case let .move(grab, start):
            let anchor = CGPoint(
                x: start.x + point.x - grab.x, y: start.y + point.y - grab.y)
            guard let box = boundingBox(
                of: session.transform.quad(of: session.localBox, anchor: anchor))
            else { return point }
            let snapped = engine.snapped(rect: box, edges: .all, in: context)
            // The anchor is `point` plus a constant, so the box's correction
            // IS the point's.
            return CGPoint(
                x: point.x + snapped.minX - box.minX,
                y: point.y + snapped.minY - box.minY)
        }
    }

}

/// The tools whose gesture the canvas snaps by itself, and so the ones whose
/// mouse-down asks `onSnapEngine` for a fresh engine. Kept here rather than
/// in the frozen canvas because the reason it is this list and not another
/// is a snapping decision: the two marquees and the lasso vertex snap a
/// POINT, the shape drag hands its engine to `ShapeToolPreview`, and every
/// other tool's press would be paying to build a list it never reads.
/// A shape RE-EDIT is not in it — that gesture's engine comes from
/// `makeSnapEngine(for: .shape)` on the controller side.
extension ImageCanvasView {
    static let snappingCanvasTools: Set<EditorTool> = [
        .select, .ellipseSelect, .lasso, .shapeRect, .shapeEllipse, .shapeLine,
    ]

    /// The marquee's click-vs-drag threshold in SCREEN POINTS: a band
    /// thinner than this on either axis is a misclick, and `mouseUp` treats
    /// it as click-to-deselect.
    ///
    /// It lives beside the snapping decisions because snapping is what made
    /// it a shared number rather than a local literal: both marquee corners
    /// snap independently, so a band narrower than one line's pull would
    /// otherwise be pulled to zero and then discarded here as a click —
    /// clearing a selection the user meant to replace with a thin one.
    /// `snappedMarqueeRect` drops the pull on exactly the axis where that
    /// would happen, which only works while the two read one number.
    static let marqueeClickScreenPoints: CGFloat = 2
}
