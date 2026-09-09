import AppKit

/// The guide gestures and the two guide COMMANDS — everything in this phase
/// that edits the document.
///
/// | Entry point | UI path it serves |
/// |---|---|
/// | `newGuide` / `clearGuides` | View ▸ New Guide… / Clear Guides |
/// | `guideMouseDown/Dragged/Up` | grabbing a guide on the canvas and moving it |
/// | `guideDragDelete` / `guideDragCancel` | ⌫ and Escape while one is grabbed |
/// | `rulerDragOut` | dragging a new guide out of a ruler strip |
/// | `rulerOriginDrag` / `resetRulerOrigin` | the ruler corner box's drag and double-click |
/// | `refreshCanvasGuides` | every document change |
///
/// The pure preference actions (rulers, units, grid, snap, colour, lock)
/// live in `EditorViewController+Rulers.swift`; only these two commands
/// change the document, which is why they are here beside the drags that
/// share their edit path.
///
/// EVERY edit here goes through `ImageDocument.applyGuideEdit`, the ONE
/// guide-edit entry point for both the UI and the agent: undo + dirty +
/// notify with no reprojection, because a guide changes no pixel and
/// re-flattening a 100 MP document per guide edit is pure waste.
///
/// ONE EDIT PER GESTURE, AT MOUSE-UP. A drag never touches the document
/// while it is in flight — the live position lives in the canvas's
/// `GuideDragSession` — so a guide dragged across the canvas is one undo
/// step, not one per mouse-moved event, and the document is not re-notified
/// (and every observer re-run) at pointer rate.
///
/// NO GUIDE EDIT UNDER AN OPEN SESSION. A text session, a Free Transform and
/// a shape re-edit are all torn down by `imageDidChange`, so any edit posted
/// underneath one silently discards it. The two menu commands answer
/// `!chromeSessionActive` in `validateViewChromeItem` and the canvas's own
/// grab is unreachable while `isTransforming`; the three RULER gestures ask
/// `refuseRulerGestureInSession()` for the same answer.
///
/// A NIL FROM THE CORE IS A BEEP, so every path that is a legitimate NO-OP
/// is checked BEFORE the edit is asked for: clicking a guide without moving
/// it, a press in a ruler that never became a drag, releasing the corner box
/// on the origin it already has, double-clicking it when the origin is
/// already (0, 0), releasing a drag on a guide an AGENT deleted while it was
/// in flight (`deleteGuide`) — and a DROP ONTO A LINE another parallel guide
/// already holds, which is a benign outcome and not a refusal (a new guide
/// is simply not created; a moved one collapses into the one there). That
/// last one is checked here rather than left to the core because snapping
/// can aim a drag straight at it. What is left — a full list, and a typed or
/// agent-supplied position out of range — really is a refusal, and beeps.
extension EditorViewController {
    // MARK: - Commands

    /// View ▸ New Guide…: orientation plus a position in the current unit,
    /// seeded with the canvas centre expressed FROM THE RULER ORIGIN
    /// (the number in that field is one the user read off a ruler).
    ///
    /// The sheet captures the unit, the ppi, the canvas size and the origin
    /// at init and converts with those four alone (`app/CLAUDE.md`'s sheet
    /// rule), so an agent's `set_resolution` or `set_ruler_origin` landing
    /// behind the sheet cannot move the guide the user asked for. It hands
    /// back an ABSOLUTE canvas coordinate, deliberately unrounded: a typed
    /// number is an exact request, unlike a dragged one.
    @objc func newGuide(_ sender: Any?) {
        guard let doc = document?.doc else {
            NSSound.beep()
            return
        }
        let origin = doc.rulerOrigin
        let sheet = NewGuideSheetController(
            unit: rulerUnit, ppi: rulerPPI, canvas: doc.canvasSize,
            rulerOrigin: CGPoint(x: origin.x, y: origin.y)
        ) { [weak self] orientation, position in
            self?.document?.applyGuideEdit(
                "New Guide",
                record: .addGuide(orientation: orientation.agentName, position: position)
            ) {
                $0.addingGuide(orientation, at: position)
            }
        }
        presentAsSheet(sheet)
    }

    /// View ▸ Clear Guides. Works while guides are LOCKED: the lock exists
    /// to stop an accidental drag, not to freeze the document. (An empty
    /// list disables the menu item, so the core's nil for "cleared nothing"
    /// cannot be reached from here.)
    @objc func clearGuides(_ sender: Any?) {
        document?.applyGuideEdit("Clear Guides", record: .clearGuides) { $0.clearingGuides() }
    }

    // MARK: - The canvas drag

    /// A press on the canvas: opens a drag when it lands on a guide.
    /// Returns true when it took the press, which is what stops the canvas
    /// from handing it to the active tool.
    ///
    /// `modifiers` is read for ⌘ ALONE — which is what lets a tool other
    /// than Move take hold of a guide, and is asked through the canvas's own
    /// `canGrabGuide` so this and the press that called it cannot answer
    /// differently. ⌃ is deliberately NOT latched here: it suspends snapping
    /// and is sampled on every TICK instead, so the user can suspend and
    /// resume mid-drag (Photoshop's behaviour) and macOS's ⌃-click
    /// contextual-menu routing cannot swallow the setting for the gesture.
    func guideMouseDown(_ point: CGPoint, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        // The canvas gates on exactly this before it calls; asking the same
        // question here keeps the rule with the thing it governs and leaves
        // one place to change it. A guide you cannot see must not move your
        // drag, a LOCKED guide is not hit-tested at all, and a tool that
        // does not own the grab never sees one — in every case the press
        // falls through to the tool, with no beep and nothing to refuse.
        guard canvas.canGrabGuide(modifiers) else { return false }
        guard let guide = GuideHitTest.guide(
            at: point, in: canvas.guides, magnification: canvas.magnification)
        else { return false }
        let pointer = guide.orientation == .horizontal ? point.y : point.x
        canvas.guideDrag = GuideDragSession(
            orientation: guide.orientation, guideID: guide.id, isNew: false,
            startPosition: guide.position, pressPoint: point,
            grabOffset: pointer - guide.position)
        canvas.guideDrag?.snap = guideSnapEngine()
        canvas.needsDisplay = true
        return true
    }

    /// One drag tick: the session moves, snaps and redraws; the document is
    /// untouched until mouse-up.
    ///
    /// The point arrives in CANVAS coordinates from both call sites — the
    /// canvas's own `mouseDragged` and the strip's, which converts — and
    /// converting it back to WINDOW space here is what lets one method ask
    /// where the pointer really is (`guidePointerInRuler`). It is exact:
    /// both sites produced it by converting the event's `locationInWindow`
    /// through this same canvas view.
    func guideMouseDragged(_ point: CGPoint, _ modifiers: NSEvent.ModifierFlags) {
        guard var drag = canvas.guideDrag else { return }
        drag.update(
            to: point, extent: CGFloat(drag.orientation.extent(inCanvas: rulerCanvasSize)),
            inRuler: guidePointerInRuler(canvas.convert(point, to: nil), drag.orientation),
            context: SnapContext(
                magnification: canvas.magnification,
                suspended: modifiers.contains(.control)))
        canvas.guideDrag = drag
        canvas.needsDisplay = true
        // A drag that began in a RULER strip is delivered to the strip, not
        // to the canvas, so the canvas's own `onCursorMove` never fires for
        // it: without this line the pointer marks would freeze for exactly
        // the gesture that most needs them.
        rulerCursorMoved(point)
    }

    /// Mouse-up: one `applyGuideEdit` — "New Guide", "Move Guide" or
    /// "Delete Guide" (dropped back into its ruler) — or nothing at all.
    ///
    /// EVERY DECISION HERE COMES FROM THE DRAG, not from the release event.
    /// Whether the guide is being dropped back into its ruler is
    /// `drag.willDelete` — the state the preview was drawn from — and the
    /// position committed is the one that preview showed. Reading the
    /// release point instead let the two disagree at the canvas edge: a last
    /// mouse-moved just outside followed by a mouse-up just inside skipped
    /// the delete and committed the out-of-canvas coordinate, which the core
    /// then refused with a beep, losing both the move and the delete.
    /// Re-snapping here would be wrong for the same family of reasons:
    /// mouse-up carries no modifier flags through this closure, so a guide
    /// the user was holding ⌃ to keep free would snap at the last instant.
    func guideMouseUp() {
        guard let drag = canvas.guideDrag else { return }
        canvas.guideDrag = nil
        canvas.needsDisplay = true

        if drag.isNew {
            // Released back inside the ruler, or never moved at all: the
            // guide was never created, so there is nothing to undo and
            // nothing to refuse. `moved` is tracked rather than inferred from
            // the pointer's canvas coordinate, which is positive — and so
            // looks like the picture — whenever the canvas is scrolled under
            // the strip.
            guard drag.moved, !drag.willDelete else { return }
            let orientation = drag.orientation
            let position = drag.committedPosition
            // Two guides of one orientation may not share a position: the
            // core refuses the duplicate, and this drag is the one gesture
            // that can be AIMED at an occupied line (by a layer edge or a
            // grid line that happens to coincide with a guide — the guides
            // themselves are already out of its target list). A drop there
            // creates nothing, silently: the line the user wanted is already
            // on screen, and a beep would report a refusal for an outcome
            // that already looks like success.
            guard !guideOccupied(orientation, at: position, excluding: 0) else { return }
            document?.applyGuideEdit(
                "New Guide",
                record: .addGuide(orientation: orientation.agentName, position: position)
            ) { $0.addingGuide(orientation, at: position) }
            return
        }

        let id = drag.guideID
        guard !drag.willDelete else {
            deleteGuide(id: id)
            return
        }
        // A click on a guide is not an edit, and neither is a drag that ends
        // where the guide already is. Both tests earn their place: the first
        // catches a press that never moved (which must not re-commit a
        // fractional guide at a whole pixel), the second a target the guide
        // already sits on — an agent can move or delete a guide behind a
        // live drag — where the core's nil would beep about a refusal that
        // never happened.
        guard !drag.isUnmoved else { return }
        let position = drag.committedPosition
        guard let doc = document?.doc, let index = doc.guideIndex(id: id),
              doc.guideInfo(index)?.position != position
        else { return }
        // Dropped onto a line another parallel guide already holds, the two
        // COLLAPSE into one: the dragged guide is deleted and the one that
        // was there stays. Photoshop's outcome, and the only one that agrees
        // with what the user saw — a guide sitting on that line — since the
        // core will not store two. Left to the core it is a refusal, and the
        // guide sprang back to where the drag started with a beep.
        guard !guideOccupied(drag.orientation, at: position, excluding: id) else {
            deleteGuide(id: id)
            return
        }
        // ONE commit, TWO calls: there is no move tool, so a drag is a
        // remove of the guide where it was plus an add where it landed. This
        // is exactly what the record parameter being an ARRAY is for, and
        // the removal names the guide by POSITION — a list index would name
        // a different guide after any earlier guide edit in the same action.
        let from = doc.guideInfo(index)?.position ?? position
        document?.applyGuideEdit(
            "Move Guide",
            record: .moveGuide(
                orientation: drag.orientation.agentName, from: from, to: position)
        ) { doc in
            // Resolved from the STABLE ID against the document the edit is
            // applied to, never from an index remembered at mouse-down: the
            // list re-sorts by position on every edit.
            guard let index = doc.guideIndex(id: id) else { return nil }
            return doc.movingGuide(index, to: position)
        }
    }

    /// ⌫ while a guide is grabbed. Reachable ONLY because Edit ▸ Clear
    /// stands down while `canvas.guideDrag != nil`: Clear owns a bare ⌫ key
    /// equivalent, and a modifier-less key equivalent is resolved ahead of
    /// the first responder, so without that guard this path would be dead
    /// whenever a selection existed — and the keystroke would clear the
    /// selection's PIXELS instead.
    func guideDragDelete() {
        guard let drag = canvas.guideDrag else { return }
        canvas.guideDrag = nil
        canvas.needsDisplay = true
        // A guide dragged out of a ruler does not exist yet, so ⌫ simply
        // abandons it — the same outcome as Escape, with nothing to delete.
        guard !drag.isNew else { return }
        deleteGuide(id: drag.guideID)
    }

    /// Escape: the guide goes back where it was, and nothing is committed.
    /// (The session held the whole move, so dropping it IS the restore.)
    func guideDragCancel() {
        guard canvas.guideDrag != nil else { return }
        canvas.guideDrag = nil
        canvas.needsDisplay = true
    }

    /// True when a guide of `orientation` other than `id` already sits on
    /// `position` — the core's own duplicate test (`doc_guide::guide_at`),
    /// mirrored here so a drag can answer BEFORE asking for an edit the core
    /// would refuse. Read from the canvas's cache, which mirrors the document
    /// on every change, so no FFI call is made at mouse-up.
    ///
    /// `id` 0 excludes nothing, which is what a guide being created wants.
    private func guideOccupied(
        _ orientation: GuideOrientation, at position: Double, excluding id: UInt64
    ) -> Bool {
        canvas.guides.contains {
            $0.orientation == orientation && $0.id != id
                && abs($0.position - CGFloat(position)) < CanvasGuide.positionEpsilon
        }
    }

    /// Whether the pointer — given in WINDOW coordinates — has gone back
    /// into the ruler that owns a guide of `orientation`. nil when the
    /// rulers are hidden, which is `GuideDragSession.isOutside`'s signal to
    /// fall back to the canvas extent.
    ///
    /// A HALF-PLANE, not the strip's rectangle: the answer is "at or beyond
    /// the strip's inner edge", measured in the strip's own coordinates on
    /// the guide's own axis. Both strips are flipped like the canvas, so
    /// `local.y <= bounds.maxY` on the top strip means "inside it, or above
    /// it" — which is what the gesture means. A rectangle test would put a
    /// 18 pt band between the well and the top of the window in which the
    /// guide was neither deleted nor visible, and would answer NO for a
    /// pointer thrown up onto the options bar, which is a release nobody
    /// makes expecting the guide to survive. The corner box needs no case of
    /// its own: it sits in the top strip's y band and in the side strip's x
    /// band, so each axis's test already includes it.
    ///
    /// ONLY the OWNING strip is asked. A horizontal guide moves in y and is
    /// thrown away upwards; a pointer over the side strip has a y the guide
    /// can perfectly well take, so that is a move, not a delete.
    private func guidePointerInRuler(
        _ windowPoint: CGPoint, _ orientation: GuideOrientation
    ) -> Bool? {
        guard ToolOptionsStore.shared.view.rulers else { return nil }
        switch orientation {
        case .horizontal:
            guard hRuler.window != nil else { return nil }
            return hRuler.convert(windowPoint, from: nil).y <= hRuler.bounds.maxY
        case .vertical:
            guard vRuler.window != nil else { return nil }
            return vRuler.convert(windowPoint, from: nil).x <= vRuler.bounds.maxX
        }
    }

    /// The one delete, shared by ⌫ and by dropping a guide into its ruler.
    ///
    /// The missing-guide check is made HERE, before the edit is asked for,
    /// by this file's own rule: a nil from the core is a BEEP, and a guide
    /// that has already gone is a legitimate no-op, not a refusal. It is
    /// reachable — agent tool calls run on the main thread through
    /// `DispatchQueue.main.sync`, so a `clear_guides` or `remove_guide`
    /// lands BETWEEN two mouse events — and without it the app beeped at the
    /// user on release for an edit nothing had refused. The move path in
    /// `guideMouseUp` already guarded this way; this one did not.
    private func deleteGuide(id: UInt64) {
        guard let doc = document?.doc, let index = doc.guideIndex(id: id),
              let info = doc.guideInfo(index)
        else { return }
        document?.applyGuideEdit(
            "Delete Guide",
            record: .removeGuide(
                orientation: info.orientation.agentName, position: info.position)
        ) { doc in
            guard let index = doc.guideIndex(id: id) else { return nil }
            return doc.removingGuide(index)
        }
    }

    /// The candidate lines a guide drag snaps to, built ONCE at mouse-down
    /// (the engine's rule — the content-bounds fold behind the layer target
    /// is a per-pixel sweep per leaf) and held in the session for the whole
    /// gesture.
    ///
    /// NO PARALLEL GUIDE IS A TARGET FOR A GUIDE DRAG. `makeSnapEngine` drops
    /// the dragged guide by id — a guide left in its own target list springs
    /// straight back to where it started and cannot be nudged by less than
    /// the pull radius — and this drops every OTHER guide on the drag's axis
    /// as well, because the core stores no two guides of one orientation at
    /// one position: such a line is the single coordinate the commit is
    /// guaranteed to refuse, so aiming a drag at it is aiming at a beep. It
    /// bit the most ordinary gesture there is, putting a second guide beside
    /// the first. (Guides on the OTHER axis are not filtered and need not be:
    /// `pull` only ever considers candidates on the axis it is asked about.)
    private func guideSnapEngine() -> SnapEngine {
        var engine = makeSnapEngine(for: .guide)
        guard let drag = canvas.guideDrag else { return engine }
        engine.lines.removeAll { $0.kind == .guide && $0.axis == drag.axis }
        return engine
    }

    // MARK: - The rulers

    /// A drag out of a ruler strip: opens a NEW guide's drag.
    ///
    /// The press lands INSIDE the strip, which converts to a canvas
    /// coordinate above or left of the canvas, so the session starts in its
    /// "will delete" state and draws nothing until the pointer reaches the
    /// picture — and a press-and-release inside the ruler creates nothing.
    func rulerDragOut(_ orientation: GuideOrientation, at point: CGPoint) {
        guard document?.doc != nil, !refuseRulerGestureInSession() else { return }
        // The same gate the canvas applies to a grab, for the same two
        // reasons: the lock exists to stop the MOUSE moving guides, and a
        // drag whose preview cannot be seen must not leave a line behind.
        // A beep rather than silence, because the strip's cursor invited the
        // drag and the user is owed the reason it did nothing.
        guard canvas.chrome.guidesVisible, !canvas.chrome.guidesLocked else {
            NSSound.beep()
            return
        }
        let coordinate = orientation == .horizontal ? point.y : point.x
        canvas.guideDrag = GuideDragSession(
            orientation: orientation, guideID: 0, isNew: true, startPosition: coordinate,
            pressPoint: point)
        canvas.guideDrag?.snap = guideSnapEngine()
        canvas.needsDisplay = true
    }

    /// The corner box's drag. `committing` false previews (the canvas draws
    /// a crosshair at the pending origin and both strips mark it on the same
    /// tick, since they describe the same point); true writes it through
    /// `applyGuideEdit("Set Ruler Origin")`.
    ///
    /// The point is CLAMPED into the canvas and ROUNDED to a whole pixel,
    /// and the preview shows the same value the commit will write. Both are
    /// deliberate: the corner box sits outside the canvas, so every one of
    /// these drags begins out of bounds and the core — which refuses an
    /// out-of-canvas origin — would answer a guaranteed beep; and a pointer
    /// is a whole-pixel instrument, so a fractional origin would make every
    /// ruler label fractional for nothing. `set_ruler_origin` over MCP stays
    /// free to be fractional, exactly as `add_guide` does.
    func rulerOriginDrag(to point: CGPoint, committing: Bool) {
        guard let doc = document?.doc else { return }
        // The session refusal, once per GESTURE rather than once per tick:
        // this closure is called on every mouse-moved event, and a beep at
        // pointer rate would be worse than the edit it is refusing. Nothing
        // was previewed either, since the first tick is refused here too.
        guard !chromeSessionActive else {
            if committing { NSSound.beep() }
            return
        }
        let size = doc.canvasSize
        let target = CGPoint(
            x: min(max(point.x.rounded(), 0), size.width),
            y: min(max(point.y.rounded(), 0), size.height))
        guard committing else {
            canvas.rulerOriginDrag = target
            canvas.needsDisplay = true
            rulerCursorMoved(target)
            return
        }
        canvas.rulerOriginDrag = nil
        canvas.needsDisplay = true
        commitRulerOrigin(x: Double(target.x), y: Double(target.y))
    }

    /// The corner box's double-click: the origin returns to the canvas's
    /// top-left. The same commit with (0, 0).
    func resetRulerOrigin() {
        guard !refuseRulerGestureInSession() else { return }
        canvas.rulerOriginDrag = nil
        canvas.needsDisplay = true
        commitRulerOrigin(x: 0, y: 0)
    }

    /// Refuses a ruler gesture — a guide dragged out of a strip, the corner
    /// box's drag, its double-click — while a text session, a Free Transform
    /// or a shape re-edit owns the document, and beeps as every other
    /// refusal in this file does.
    ///
    /// The RULERS ARE THE ONLY UNGATED PATH to a guide edit, which is why
    /// the test belongs here: View ▸ New Guide… and Clear Guides already
    /// answer `!chromeSessionActive` from `validateViewChromeItem`, and the
    /// canvas's own grab is unreachable while `isTransforming`. Without it
    /// these three gestures post `.imageDocumentImageDidChange`, and
    /// `imageDidChange` responds by DROPPING the open transform or
    /// shape-edit session — an in-progress box thrown away, with no prompt
    /// and no undo step to bring it back, by a gesture that changes no
    /// pixel.
    private func refuseRulerGestureInSession() -> Bool {
        guard chromeSessionActive else { return false }
        NSSound.beep()
        return true
    }

    /// The one origin write. An origin that is already there is not an edit
    /// — no undo step and, because nothing was refused, no beep either
    /// (double-clicking an unmoved corner box is the common case).
    private func commitRulerOrigin(x: Double, y: Double) {
        guard let doc = document?.doc else { return }
        let current = doc.rulerOrigin
        guard current.x != x || current.y != y else { return }
        document?.applyGuideEdit("Set Ruler Origin", record: .setRulerOrigin(x: x, y: y)) {
            $0.settingRulerOrigin(x: x, y: y)
        }
    }

    // MARK: - Cache

    /// Reads the document's guides into the canvas's cache, so a redraw and
    /// a hit test cross the FFI boundary not at all. Called from
    /// `imageDidChange`.
    ///
    /// Guarded on the value, not on the notification: `imageDidChange` fires
    /// for every edit in the app and almost none of them touch a guide, so
    /// an unguarded redraw here would be a full canvas repaint per stroke
    /// tick. (The list is a handful of entries, so the comparison is far
    /// cheaper than the paint it saves.)
    func refreshCanvasGuides() {
        let guides = document?.doc?.guides.map(CanvasGuide.init) ?? []
        guard guides != canvas.guides else { return }
        canvas.guides = guides
        canvas.needsDisplay = true
    }
}
