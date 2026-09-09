import AppKit

/// The recording half of Actions: the ONE place a step lands, wherever it
/// came from.
///
/// Two feeds reach it, and only two:
///
/// 1. **The UI**, through the `record: [ActionStep]` parameter that every
///    `ImageDocument` commit entry point now takes. The commit method calls
///    `record(_:)` on its SUCCESS path only — after the handle has actually
///    been replaced — so a beeped core refusal, a cancelled sheet, a
///    cancelled rasterize prompt and a `nil` transform all record nothing,
///    for free, because they return before the record line.
/// 2. **The agent**, through one line in `AgentServer.execute`, which covers
///    every tool, the HTTP MCP server and the built-in assistant panel at
///    once.
///
/// Main thread only — every one of its callers already is (AppKit events and
/// the two agent trampolines' `DispatchQueue.main.sync`), so it needs no
/// lock and asserts the fact rather than pretending otherwise.
final class ActionRecorder {
    static let shared = ActionRecorder()

    /// Posted when a step lands, recording starts, or recording stops, so
    /// the Actions window can show a recording growing live.
    static let didChange = Notification.Name("rasterizeActionRecorderDidChange")

    private(set) var isRecording = false

    /// Set for the length of a replay (an Action run, ⌃F, a Batch file) so
    /// the player never records itself. Deliberately a plain flag rather
    /// than a suspend/resume count: replays do not nest — `ActionPlayer.run`
    /// is synchronous and the only writer.
    ///
    /// A menu command run from the COMMAND PALETTE is not a replay and IS
    /// recorded: the palette is a way to reach a command, not a way to run
    /// an action.
    var isSuspended = false

    private(set) var steps: [ActionStep] = []

    /// How much of the budget the session has spent — see `maxRecordedPoints`.
    private var recordedPoints = 0

    /// Set once the session has spent its budget: the placeholder saying so
    /// is already the last step, and nothing more is appended.
    private var isFull = false

    /// What one recording may hold before it stops taking steps.
    ///
    /// **A recording of a normal retouching session was unbounded, and the
    /// file it produced was unusable.** Measured: 150 strokes at the
    /// recorder's own 10,000-point cap is 34.7 MB compact and 124.4 MB as
    /// the app wrote it; decoding one such file blocked the app for 8.7 s
    /// and left 800 MB of RSS behind, and every Enabled checkbox in the
    /// Actions window rewrote the whole thing. Nothing warned, and the
    /// in-memory recording was ~100 MB before it was ever saved.
    ///
    /// So the session has a budget, and spending it is VISIBLE: the
    /// placeholder appended at the limit says the recording stopped and why,
    /// exactly like every other gap this feature refuses to leave silent.
    /// Deleting steps in the Actions window gives the budget back
    /// (`replaceSteps` recomputes it), so a user who trims the strokes can
    /// carry on recording.
    ///
    /// 200,000 points is about 4.6 MB of compact JSON — twenty full-length
    /// sweeps, or hundreds of ordinary ones — and 1,000 steps is far more
    /// menu commands than a session anyone would replay.
    static let maxSteps = 1000
    static let maxRecordedPoints = 200_000

    /// The canvas the recording was made on — the size the FIRST recorded
    /// step was authored against, before that step ran. Reported on a size
    /// mismatch at replay; never used to remap a coordinate.
    ///
    /// Nil while nothing has been recorded, and nil again once two steps have
    /// been recorded against different documents (see `noteCanvas`).
    private(set) var recordedCanvas: (width: Int, height: Int)?

    /// The document the recording's steps have targeted so far, weakly. The
    /// canvas belongs to a DOCUMENT, so this is what decides whether a later
    /// step belongs to the same recording's coordinate space — a step that
    /// resized the canvas does not.
    private weak var recordedDocument: ImageDocument?

    /// True once `recordedDocument` has been set, so a document that has
    /// since closed is still distinguishable from one never seen.
    private var hasRecordedDocument = false

    /// Set once two recorded steps have named different documents. There is
    /// then no ONE canvas this recording was made against, and a warning
    /// about the wrong one is worse than no warning at all.
    private var canvasIsAmbiguous = false

    /// The last repeatable filter or adjustment, for Filters ▸ Repeat Last.
    ///
    /// Updated whether or not recording is on, because ⌃F has to work
    /// without it — which is the whole reason it lives on the recorder
    /// rather than in the recording.
    private(set) var lastRepeatable: ActionStep?

    private init() {}

    // MARK: - The session

    /// True when a stopped session's steps are still here, waiting to be
    /// saved or thrown away. `start()` DISCARDS them, so both entry points
    /// that can start a session ask first (`AppDelegate.toggleActionRecording`
    /// puts up the alert; `start_recording` refuses unless `discard` is
    /// passed) — the steps live only in memory, no file holds them and no
    /// undo covers them.
    var hasUnsavedRecording: Bool { !isRecording && !steps.isEmpty }

    func start() {
        assert(Thread.isMainThread)
        isRecording = true
        steps = []
        recordedPoints = 0
        isFull = false
        // Not captured here: `currentDocument` at the moment Record is
        // pressed need not be the document the steps go on to edit — an
        // agent driving the app in the background has no current document at
        // all. The first recorded step says which document it targeted, and
        // that is where the size comes from.
        recordedCanvas = nil
        recordedDocument = nil
        hasRecordedDocument = false
        canvasIsAmbiguous = false
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Ends the session and hands back what it captured.
    @discardableResult
    func stop() -> [ActionStep] {
        assert(Thread.isMainThread)
        isRecording = false
        let captured = steps
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return captured
    }

    /// The session's steps as an action ready to save.
    func recording(named name: String) -> Action {
        Action(
            name: name, steps: steps, recordedCanvas: recordedCanvas, raw: nil,
            created: Date(), modified: Date())
    }

    // MARK: - The one entry point

    /// Records `steps`, if a session is running and not suspended, and
    /// latches the last repeatable one either way.
    ///
    /// An empty array — `.notACommand` — is the common case at the sites
    /// that deliberately record nothing, and costs a branch.
    ///
    /// `document` is the one the steps were made against. The four
    /// `ImageDocument` commit hooks pass themselves and the agent passes the
    /// document its call resolved to; the handful of remaining UI sites pass
    /// none and mean "the front one", which for a gesture in a window is the
    /// same thing.
    ///
    /// `canvas` is that document's size BEFORE the steps ran, which is the
    /// size their absolute coordinates were written against — the four commit
    /// hooks have the pre-edit handle in hand and pass it, and the agent
    /// samples it before it dispatches. nil means "read it from the document
    /// now", which is right for the sites that cannot resize a canvas (a
    /// selection gesture, a layer-panel click) and is the only answer
    /// available to a step that CREATED the document it targeted.
    func record(
        _ steps: [ActionStep], on document: ImageDocument? = nil,
        canvas: (width: Int, height: Int)? = nil
    ) {
        assert(Thread.isMainThread)
        guard !steps.isEmpty, !isSuspended else { return }
        for step in steps where ActionCatalogFacts.repeatableTools.contains(step.tool) {
            lastRepeatable = step
        }
        guard isRecording, !isFull else { return }
        noteCanvas(of: document, size: canvas)
        self.steps.append(contentsOf: steps)
        recordedPoints += steps.reduce(0) { $0 + Self.weight(of: $1) }
        if self.steps.count >= Self.maxSteps || recordedPoints >= Self.maxRecordedPoints {
            isFull = true
            let reason =
                self.steps.count >= Self.maxSteps
                ? "\(Self.maxSteps) steps" : "\(Self.maxRecordedPoints) stroke points"
            self.steps.append(
                contentsOf: [ActionStep].unrecorded(
                    "Recording stopped at \(reason) — later edits were not recorded"))
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// What one step spends of the budget: the length of its `points` array
    /// — a stroke's flattened polyline or a lasso's outline, which is where
    /// every large recorded payload lives — and 1 for everything else.
    ///
    /// Through `NSArray` deliberately: `as? [Any]` would COPY the array to
    /// count it, on every step, which is the kind of cost this budget exists
    /// to bound. `count` through the bridge is O(1) for both shapes the
    /// recorder sees (a UI factory's `[[Double]]` and an agent call's parsed
    /// JSON) — measured.
    private static func weight(of step: ActionStep) -> Int {
        max(1, (step.arguments["points"] as? NSArray)?.count ?? 1)
    }

    /// A live GESTURE's steps — the `endLiveEdit` hook — built only when a
    /// session is actually running.
    ///
    /// **Why this one is lazy and `record` is not.** A stroke's step carries
    /// the gesture's whole flattened polyline, up to the recorder's own
    /// 10,000-point cap, and building it measured 16 ms at mouse-up on a
    /// long sweep (almost all of it in `ActionStep`'s sanitising walk) — a
    /// cost the app was paying on EVERY stroke, whether or not anyone was
    /// recording, because the argument was evaluated at the call site.
    /// `record` cannot be lazy the same way: it also latches
    /// `lastRepeatable`, which ⌃F needs with no recording running, and that
    /// latch has to see the step.
    ///
    /// Nothing is lost by skipping the build here, and the assert says so: a
    /// gesture's step is never one of the four repeatable tools, which are
    /// all menu commands committing through `applyEdit`.
    func recordGesture(
        _ steps: @autoclosure () -> [ActionStep], on document: ImageDocument? = nil,
        canvas: (width: Int, height: Int)? = nil
    ) {
        let steps = gestureRecord(steps())
        guard !steps.isEmpty else { return }
        record(steps, on: document, canvas: canvas)
    }

    /// `recordGesture`'s guard, for a gesture that cannot call it: the
    /// coverage-stroke commit goes through `ImageDocument.applyEdit` /
    /// `applyRasterizingEdit`, whose `record:` is an ordinary parameter
    /// because the `lastRepeatable` latch has to see every menu command's
    /// step. The answer is the same guard, applied at the site, so the
    /// expression is built only when a session is actually collecting it.
    ///
    /// Painting into a layer MASK is the commonest coverage gesture there is,
    /// and it was paying the whole build at every mouse-up with nothing
    /// running: `recordablePoints` walks the flattened polyline, one
    /// `[Double]` is allocated per vertex up to the 10,000-point cap, and
    /// `ActionStep.init` then walks the result again to ask
    /// `isValidJSONObject` (4.7 ms of the 16 ms, measured) — for a value
    /// `record` immediately discarded.
    ///
    /// Returns the empty array — `.notACommand` — when nothing is listening,
    /// which is exactly what those commit points take for "records nothing".
    func gestureRecord(_ steps: @autoclosure () -> [ActionStep]) -> [ActionStep] {
        assert(Thread.isMainThread)
        guard isRecording, !isSuspended else { return [] }
        let steps = steps()
        assert(
            !steps.contains { ActionCatalogFacts.repeatableTools.contains($0.tool) },
            "a gesture recorded a repeatable tool — the lastRepeatable latch would miss it")
        return steps
    }

    /// One agent tool call, recorded VERBATIM apart from `document_id`.
    ///
    /// The agent said what it meant — an explicit layer index, an explicit
    /// target, an explicit colour — and second-guessing those into symbols
    /// would be a lie about what was asked for. The id is the one exception:
    /// it is a session-scoped integer minted by `AgentServer.id(for:)` and
    /// means nothing on a later run, so the player rebinds it.
    func recordAgentCall(
        _ tool: String, _ arguments: [String: Any], on document: ImageDocument?,
        canvas: (width: Int, height: Int)? = nil
    ) {
        guard !ActionCatalogFacts.nonRecordable.contains(tool) else { return }
        // `record`'s own two guards, asked before the step is BUILT: a call
        // nobody is collecting and whose tool the ⌃F latch does not want
        // costs an `ActionStep.init`, which walks the whole argument tree
        // with `isValidJSONObject` — the agent's stroke tools carry a
        // caller's entire polyline, so that is the same walk the gesture
        // paths take care not to make.
        guard !isSuspended, isRecording || ActionCatalogFacts.repeatableTools.contains(tool)
        else { return }
        var arguments = arguments
        arguments.removeValue(forKey: "document_id")
        record(
            [ActionStep(tool: tool, arguments: arguments, note: "MCP: \(tool)")],
            on: document, canvas: canvas)
    }

    /// Editing steps in place, for the Actions window's row commands. The
    /// window owns the presentation; the session's array lives here.
    func replaceSteps(_ steps: [ActionStep]) {
        assert(Thread.isMainThread)
        self.steps = steps
        // The budget follows the steps: deleting the paint strokes that
        // filled a recording gives it room to carry on.
        recordedPoints = steps.reduce(0) { $0 + Self.weight(of: $1) }
        isFull = steps.count >= Self.maxSteps || recordedPoints >= Self.maxRecordedPoints
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Binds the recording's canvas to the document a step actually targeted,
    /// at the size that step was authored against.
    ///
    /// It used to be taken from `currentDocument` — falling back to the
    /// OLDEST open document when there was none — at the moment recording
    /// started. Both halves were wrong for the case Actions exist for: an
    /// agent driving the app in the background has no current document, so a
    /// recording made entirely over MCP took the size of whichever file
    /// happened to be opened first, and then warned about a mismatch on the
    /// very document it was recorded from.
    ///
    /// **Two things are load-bearing here, and both were wrong.**
    ///
    /// 1. The size comes from the caller, sampled BEFORE its step ran. Every
    ///    hook records after the handle has been replaced, so re-reading the
    ///    document gave the size the step LEFT: a recording of
    ///    `crop {0, 0, 300, 200}` on a 1024 × 768 photo saved
    ///    `recorded_canvas: 300 × 200`, so replaying it on the 1024 × 768
    ///    original — the one canvas those coordinates were written for —
    ///    warned, and replaying it on a 300 × 200 document, where the crop is
    ///    meaningless, said nothing.
    /// 2. Steps that disagree about the SIZE are normal; steps that disagree
    ///    about the DOCUMENT are not. A recording holding any canvas-resizing
    ///    step (crop, rotate, image_size, canvas_size) saw two sizes and
    ///    dropped the canvas entirely — measured, a grayscale + new_layer +
    ///    rotate recording saved `recorded_canvas: null` — which silenced the
    ///    mismatch warning for exactly the actions whose coordinates a resize
    ///    makes most dangerous. Identity is the real question, and it is the
    ///    one asked now: the size is latched once, from the first step, and
    ///    dropped only when a later step targets a different document.
    private func noteCanvas(of document: ImageDocument?, size: (width: Int, height: Int)?) {
        guard !canvasIsAmbiguous else { return }
        guard let target = document
            ?? (NSDocumentController.shared.currentDocument as? ImageDocument)
        else { return }
        if hasRecordedDocument, recordedDocument !== target {
            // Including the case where the first document has been closed and
            // deallocated: a step on another one is a step in another
            // coordinate space either way.
            recordedCanvas = nil
            canvasIsAmbiguous = true
            return
        }
        recordedDocument = target
        hasRecordedDocument = true
        guard recordedCanvas == nil else { return }
        guard let authored = size ?? target.doc.map({ (width: $0.width, height: $0.height) }),
              authored.width > 0, authored.height > 0
        else { return }
        recordedCanvas = authored
    }
}
