import AppKit

/// The guide and ruler-origin tools:
///
/// | Handler | UI path it mirrors |
/// |---|---|
/// | `listGuides` | the guides drawn on the canvas (View ▸ Show Guides) |
/// | `addGuide` | View ▸ New Guide…, and dragging a guide out of a ruler |
/// | `removeGuide` | dragging a guide back into its ruler, or ⌫ while it is grabbed |
/// | `clearGuides` | View ▸ Clear Guides |
/// | `setRulerOrigin` | dragging from the ruler corner box (double-click resets it) |
///
/// POSITIONS ARE ABSOLUTE CANVAS PIXELS, y down from the top-left — NOT
/// measured from the ruler origin. The origin is reported in every
/// `get_document` reply, so a model that wants ruler-relative arithmetic can
/// do it explicitly. There is no `unit` argument: the document already
/// reports `resolution`, so a model can convert.
///
/// NO `move_guide`. A move is `remove_guide` + `add_guide`, and — because
/// the list is re-sorted by position on every edit — an index-stable "move"
/// would be a promise the model cannot rely on.
///
/// THE THREE ANSWERS COME FROM HANDLER PRE-CHECKS, NOT FROM THE CORE. The
/// core returns one undifferentiated nil for a duplicate, an out-of-canvas
/// position and a full list, and an `editGuides`-shaped wrapper returns a
/// single Bool, so a handler that just forwarded could not tell them apart.
/// The order is fixed and each mutator states it:
///   1. parse, then range- and finiteness-check the position against the
///      canvas, and THROW naming the legal range (`set_resolution`'s
///      precedent: "the difference between telling the model its number was
///      wrong and silently clamping 0.5 to 1 and calling that a change");
///   2. scan `doc.guides` for a same-orientation match and return
///      `noOpResult` — a duplicate is a no-op, not a failure
///      (`rename_channel`'s precedent);
///   3. treat any surviving nil as THE CAP and answer with a message naming
///      `RasterDocument.maxGuides`, never a generic "check the parameters".
///
/// `editGuides` COPIES `performGroupedEdit`'s LOOP, NOT ITS CALL.
/// `performGroupedEdit` reaches `ImageDocument.applyEdit`, the REPROJECTING
/// path `applyGuideEdit` exists to avoid, and using it would make a second
/// entry point for the same edit. But its grouping loop is exactly what an
/// off-event-path edit needs: `app/CLAUDE.md` warns that an undo
/// registration outside an AppKit event lands in an implicit group that
/// never closes, so without it three `add_guide` calls followed by one
/// `undo` would remove all three.
///
/// VIEW PREFERENCES GET NO TOOL AT ALL, and that is a decision, not an
/// omission. Rulers, the grid, the snap toggles and the ruler unit live in
/// `UserDefaults` and are app-wide, so (1) the `document_id` every catalog
/// tool carries would be a lie — a call naming one document would change
/// every other open window; (2) there is no undo step that can walk one
/// back, which would make it the only mutation in the surface `undo` cannot
/// reverse; (3) a model has no pointer and never benefits from a snap — it
/// computes the coordinate it wants and passes it at full precision; and
/// (4) a preference writes nothing a `save_copy` would carry. Guides and the
/// ruler origin are the opposite on all four counts — per-document,
/// undoable, `.rz`-persisted — so they get the full set.
extension AgentServer {
    // MARK: - The guide list

    /// The document's guides, in the core's own order (orientation, then
    /// position).
    ///
    /// The `ruler` block rides along, from the same builder `get_document`
    /// uses: the one thing a model reading this list is likely to want next
    /// is the origin those positions are NOT measured from, and a second
    /// call to learn it would be a round trip for two numbers.
    func listGuides(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        return try jsonResult([
            "ok": true, "guides": Self.guideFields(doc), "ruler": Self.rulerFields(doc),
        ])
    }

    // MARK: - Guide CRUD

    /// View ▸ New Guide… / dragging one out of a ruler. One undo step.
    ///
    /// The three pre-checks of this file's header, in their fixed order:
    /// an unusable position THROWS naming the range, a duplicate answers
    /// `changed: false`, and only then can a nil mean the cap.
    func addGuide(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let orientation = try orientationArgument(a)
        let axis = Self.orientationName(orientation)
        guard let requested = doubleArg(a, "position") else {
            throw ToolError(
                message: "add_guide requires position — canvas pixels along the guide's own "
                    + "axis (x for a vertical guide, y for a horizontal one).")
        }
        // 1. Range and finiteness. Both ends are legal: a guide may sit
        // exactly on a canvas edge, which is the whole point of dragging one
        // out to trim against.
        let extent = orientation.extent(inCanvas: doc.canvasSize)
        guard requested.isFinite, requested >= 0, requested <= extent else {
            throw ToolError(
                message: "position must be between 0 and \(Self.spelled(extent)) for a \(axis) "
                    + "guide on this \(doc.width) × \(doc.height) canvas (got "
                    + "\(Self.spelled(requested))). Positions are absolute canvas pixels, not "
                    + "measured from the ruler origin.")
        }
        // 2. A guide already on that line. Compared with ==, after the same
        // four-decimal quantization the core applies, because that IS the
        // core's own duplicate test — anything looser would report a
        // duplicate the core would then happily add.
        let position = Self.q4(requested)
        if let existing = Self.guideIndex(doc, orientation, position) {
            return try noOpResult(
                [
                    "guide": existing, "orientation": axis,
                    "position": Self.jsonNumber(position),
                    "guides": doc.guideCount,
                ],
                why: "a \(axis) guide already sits at \(Self.spelled(position)).")
        }
        // 3. Whatever the core refuses now is the cap, and says so.
        guard try editGuides(document, "New Guide", { $0.addingGuide(orientation, at: position) }),
              let updated = document.doc
        else {
            return try guideListFullResult(
                ["orientation": axis, "position": Self.jsonNumber(position)])
        }
        // The list re-sorts on every edit, so the new guide is not
        // necessarily last: report where it actually landed. The lookup
        // cannot miss — the core just accepted this exact quantized
        // position — but a wrong index here would send the next
        // `remove_guide` at somebody else's guide, so a miss reports no
        // index at all rather than a plausible one.
        var result: [String: Any] = [
            "ok": true, "orientation": axis, "position": Self.jsonNumber(position),
            "guides": updated.guideCount,
        ]
        if let index = Self.guideIndex(updated, orientation, position) {
            result["guide"] = index
        }
        return try jsonResult(result)
    }

    /// Dragging a guide back into its ruler, or ⌫ while it is grabbed. One
    /// undo step.
    ///
    /// The guide is read BEFORE the edit so the reply can name what went
    /// away — after it, the index means a different guide or nothing at all
    /// (`delete_channel`'s shape).
    func removeGuide(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let index = try guideArgument(a, doc)
        let removed = doc.guideInfo(index)
        guard try editGuides(document, "Delete Guide", { $0.removingGuide(index) }) else {
            // The core's only refusal is an out-of-range index, which
            // `guideArgument` has already turned into a thrown message, so
            // this is the belt to that braces.
            return try noOpResult(
                ["guide": index], why: "guide \(index) could not be removed.")
        }
        var result: [String: Any] = [
            "ok": true, "guide": index, "guides": document.doc?.guideCount ?? 0,
        ]
        if let removed = removed {
            result["orientation"] = Self.orientationName(removed.orientation)
            result["position"] = Self.jsonNumber(removed.position)
        }
        return try jsonResult(result)
    }

    /// View ▸ Clear Guides. Works while guides are LOCKED: the lock stops an
    /// accidental drag, not the document.
    func clearGuides(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let before = doc.guideCount
        guard try editGuides(document, "Clear Guides", { $0.clearingGuides() }) else {
            // The core's ONLY refusal here is an already-empty list, so this
            // needs no pre-check to be specific.
            return try noOpResult(["guides": 0], why: "this document has no guides.")
        }
        return try jsonResult(["ok": true, "removed": before, "guides": 0])
    }

    // MARK: - The ruler origin

    /// The ruler corner box's drag; (0, 0) is its double-click reset. The
    /// origin moves the rulers' LABELS and the New Guide sheet's typed
    /// number — no grid, no snap target, and no coordinate any other tool
    /// reports. One undo step.
    ///
    /// The same three steps as `addGuide`, minus a cap: a document has
    /// exactly one origin, so there is nothing for a list to be full of.
    func setRulerOrigin(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard let requestedX = doubleArg(a, "x"), let requestedY = doubleArg(a, "y") else {
            throw ToolError(
                message: "set_ruler_origin requires x and y — canvas pixels from the left and "
                    + "from the top.")
        }
        // 1. Range and finiteness. The origin is a point INSIDE the canvas
        // (both ends legal, like a guide), so a model that wanted "one inch
        // in" and computed with the wrong ppi is told its number was wrong
        // rather than quietly clamped to a corner.
        guard requestedX.isFinite, requestedY.isFinite,
              requestedX >= 0, requestedX <= Double(doc.width),
              requestedY >= 0, requestedY <= Double(doc.height)
        else {
            throw ToolError(
                message: "x must be between 0 and \(doc.width) and y between 0 and "
                    + "\(doc.height) — the ruler origin is a point inside the canvas (got "
                    + "\(Self.spelled(requestedX)), \(Self.spelled(requestedY))).")
        }
        // 2. The origin it already has, after the core's own quantization,
        // so a value read out of get_document and echoed back registers no
        // phantom undo step.
        let (x, y) = (Self.q4(requestedX), Self.q4(requestedY))
        let current = doc.rulerOrigin
        if x == current.x, y == current.y {
            return try noOpResult(
                ["origin_x": Self.jsonNumber(x), "origin_y": Self.jsonNumber(y)],
                why: "the ruler origin is already at "
                    + "(\(Self.spelled(x)), \(Self.spelled(y))).")
        }
        guard try editGuides(document, "Set Ruler Origin", { $0.settingRulerOrigin(x: x, y: y) })
        else {
            // Unreachable in practice: the two checks above ARE the core's
            // refusals for this op (non-finite, outside the canvas after
            // quantization, and no change), and there is no cap. Answered in
            // band rather than thrown so a disagreement between the two
            // still reads as "nothing changed" instead of a failure.
            return try noOpResult(
                ["origin_x": Self.jsonNumber(x), "origin_y": Self.jsonNumber(y)],
                why: "the core did not accept that origin.")
        }
        var result: [String: Any] = ["ok": true, "changed": true]
        if let updated = document.doc {
            result["ruler"] = Self.rulerFields(updated)
        }
        result["note"] =
            "Only the on-screen rulers' labels and View ▸ New Guide…'s field move with the "
            + "origin: guides, the grid, every snap target and every coordinate this API "
            + "reports stay measured from the canvas top-left."
        return try jsonResult(result)
    }

    // MARK: - Field builders shared with get_document

    /// The guide rows `list_guides` and `get_document` both report — ONE
    /// builder, two callers, exactly like `channelFields`.
    ///
    /// Built from the core's indices rather than by numbering a filtered
    /// array, so a row that failed to read could never renumber the ones
    /// after it: an index is what `remove_guide` takes.
    static func guideFields(_ doc: RasterDocument) -> [[String: Any]] {
        (0..<doc.guideCount).compactMap { index -> [String: Any]? in
            guard let guide = doc.guideInfo(index) else { return nil }
            return [
                "index": index,
                "orientation": orientationName(guide.orientation),
                "position": jsonNumber(guide.position),
            ]
        }
    }

    /// The ruler block `get_document` always carries: the origin (document
    /// state) and the unit the rulers are currently drawn in, which is an
    /// APP-WIDE PREFERENCE and is labelled as one in the catalog.
    ///
    /// The unit is reported because a model reading a print-size figure has
    /// no other way to know which numbers the human beside it is reading off
    /// the rulers; it is NOT settable, for the four reasons in this file's
    /// header, and no API coordinate is expressed in it.
    static func rulerFields(_ doc: RasterDocument) -> [String: Any] {
        let origin = doc.rulerOrigin
        let unit = CanvasUnit(rawValue: ToolOptionsStore.shared.view.rulerUnitIndex) ?? .pixels
        return [
            "origin_x": jsonNumber(origin.x),
            "origin_y": jsonNumber(origin.y),
            "unit": unit.abbreviation,
        ]
    }

    // MARK: - Shared pieces

    /// One guide edit, off the event path like every agent edit, with the
    /// core's refusal handed back rather than thrown. Returns false when the
    /// op answered nil — after the callers' own pre-checks that means the
    /// cap, or an already-empty list — and rethrows anything else.
    ///
    /// This is `performGroupedEdit`'s grouping LOOP around
    /// `ImageDocument.applyGuideEdit`, and the two halves of that sentence
    /// are each load-bearing:
    ///
    /// - it does NOT call `performGroupedEdit`, which reaches `applyEdit`
    ///   and re-flattens the whole document — the reprojecting path
    ///   `applyGuideEdit` exists to avoid, and a second entry point for the
    ///   same edit;
    /// - it does NOT call `applyGuideEdit` bare, because an undo
    ///   registration outside an AppKit event lands in an implicit event
    ///   group that never closes (`app/CLAUDE.md`), so three `add_guide`
    ///   calls would collapse into one undo step and a single `undo` would
    ///   take all three guides away.
    ///
    /// The transform runs FIRST, as it does there, so a refused edit never
    /// opens a group — and never reaches `applyGuideEdit`, whose own nil
    /// path beeps at a user who is not there.
    private func editGuides(
        _ document: ImageDocument, _ actionName: String,
        _ transform: (RasterDocument) -> RasterDocument?
    ) throws -> Bool {
        guard let current = document.doc else {
            throw ToolError(message: "Document has no image")
        }
        guard let updated = transform(current) else { return false }
        // The grouping loop this comment used to ask a third caller to hoist
        // is hoisted: `withUndoGroup` (UndoGrouping.swift) is the one copy,
        // shared with `performGroupedEdit`, and its drain is level-relative
        // so a guide edit replayed from inside an AppKit event does not close
        // the event's own implicit group.
        withUndoGroup(document.undoManager) {
            document.applyGuideEdit(actionName, record: .notACommand) { _ in updated }
        }
        return true
    }

    /// The in-band "nothing changed" answer. Never an error: no undo step
    /// opened and no byte moved, and saying so plainly is what lets a model
    /// carry on instead of retrying the identical call.
    ///
    /// Copied from `AgentServer+Channels`, where it is `private`. A THIRD
    /// feature needing it should hoist this into a shared file rather than
    /// make a third copy — as `editGuides`' grouping loop now is
    /// (`withUndoGroup`).
    private func noOpResult(_ fields: [String: Any], why: String) throws -> String {
        // The tool's own keys never overwrite the shared ones, so a refusal
        // cannot be disguised as a success.
        try jsonResult(
            fields.merging([
                "ok": true, "changed": false,
                "note": "Nothing changed: \(why) No undo step was added.",
            ]) { _, shared in shared })
    }

    /// The refusal `add_guide` gives once its own range and duplicate checks
    /// have passed: the cap is then the only thing the core can be refusing,
    /// and naming it is the difference between a model deleting a guide and
    /// a model retrying the identical call.
    ///
    /// The number comes from `RasterDocument.maxGuides`, which asks the core
    /// (`rz_max_guides`), so it cannot drift from `doc_guide::MAX_GUIDES`.
    private func guideListFullResult(_ fields: [String: Any]) throws -> String {
        try noOpResult(
            fields,
            why: "this document already holds the maximum \(RasterDocument.maxGuides) guides. "
                + "Remove one with remove_guide, or all of them with clear_guides, first.")
    }

    // MARK: - Argument parsing

    /// The `orientation` argument. A closed two-word vocabulary, so a
    /// misspelling is named rather than defaulted: guessing "vertical" for
    /// "v-line" would put a line across the wrong axis of the picture.
    private func orientationArgument(_ a: [String: Any]) throws -> GuideOrientation {
        guard let raw = stringArg(a, "orientation") else {
            throw ToolError(
                message: "add_guide requires orientation: \"horizontal\" (a line of constant "
                    + "y) or \"vertical\" (constant x).")
        }
        switch raw.lowercased() {
        case "horizontal": return .horizontal
        case "vertical": return .vertical
        default:
            throw ToolError(
                message: "orientation must be \"horizontal\" or \"vertical\" (got \"\(raw)\")")
        }
    }

    /// A `guide` argument: an index into `list_guides`.
    ///
    /// An EMPTY list gets its own sentence, ahead of the range check, for
    /// the reason `channelArgument` gives: the range form would read
    /// "(0..-1)", which sends a model looking for the index that fits
    /// instead of telling it there is no guide to address at all.
    private func guideArgument(_ a: [String: Any], _ doc: RasterDocument) throws -> Int {
        // Through `intArg`, so "3" and 3 mean the same index here as
        // everywhere else in the surface.
        guard let index = intArg(a, "guide") else {
            throw ToolError(message: "remove_guide requires guide — an index from list_guides.")
        }
        guard doc.guideCount > 0 else {
            throw ToolError(
                message: "This document has no guides, so guide \(index) names nothing. "
                    + "Create one with add_guide.")
        }
        guard index >= 0, index < doc.guideCount else {
            throw ToolError(
                message: "Guide \(index) is out of range (0..\(doc.guideCount - 1)). Indices "
                    + "shift after any guide edit, so read list_guides immediately before.")
        }
        return index
    }

    // MARK: - Numbers and names

    /// The index of the guide of `orientation` sitting exactly on
    /// `position` (already quantized), if any — the duplicate test
    /// `add_guide` shares with the core's own `guide_at`.
    private static func guideIndex(
        _ doc: RasterDocument, _ orientation: GuideOrientation, _ position: Double
    ) -> Int? {
        (0..<doc.guideCount).first {
            guard let guide = doc.guideInfo($0) else { return false }
            return guide.orientation == orientation && guide.position == position
        }
    }

    private static func orientationName(_ orientation: GuideOrientation) -> String {
        orientation == .horizontal ? "horizontal" : "vertical"
    }

    /// The core's four-decimal quantization, mirrored exactly (`q4_f64` is
    /// `(v * 1e4).round() / 1e4`, and Swift's `.rounded()` is Rust's
    /// `round`: nearest, halves away from zero). Both sides therefore
    /// produce the same bits, which is what makes an `==` duplicate test —
    /// the core's own — the right one here rather than a tolerance.
    private static func q4(_ value: Double) -> Double {
        (value * 10000).rounded() / 10000
    }

    /// A core four-decimal value spelled the way the core wrote it.
    /// JSONSerialization writes a Double with 17 significant digits
    /// (250.1 → 250.10000000000002), which would misreport a quantized
    /// position and make a model's echo of it look like a different number;
    /// a decimal built from Swift's shortest round-trip spelling prints as
    /// the core stored it. The same trick as `globalLightFields`, for the
    /// same reason.
    private static func jsonNumber(_ value: Double) -> NSNumber {
        // A non-finite value cannot be JSON and would make jsonResult throw.
        // The core never stores one (every position and origin component is
        // finiteness-checked before it is kept), so this is a serialization
        // guard, not a policy.
        guard value.isFinite else { return 0 }
        return NSDecimalNumber(string: "\(value)")
    }

    /// The same number as prose, for the notes and the error messages, so
    /// what a refusal says and what the JSON carries cannot disagree.
    private static func spelled(_ value: Double) -> String {
        jsonNumber(value).stringValue
    }
}
