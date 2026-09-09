import AppKit

/// Running an action: symbol resolution, per-step execution through the
/// SAME dispatch an MCP client reaches, and the failure policy.
///
/// Every step runs through `AgentServer.shared.execute(tool:argumentsJSON:)`
/// on the main thread. That is deliberate and it is the whole reason Actions
/// are affordable: replay needs no second implementation of anything,
/// because every user-visible edit already has an MCP twin.
///
/// **Undo granularity: ONE undo step for the whole action, and none when
/// nothing changed.** `run` hands the loop to `ImageDocument.withReplayUndo`,
/// which suppresses the steps' own registrations and registers a single
/// snapshot restore afterwards — but only if the document handle actually
/// moved, so a run whose steps all failed or were all disabled leaves no
/// phantom "Undo <action>" behind and consumes none of the 24 undo levels.
/// That method's own comment carries the measurement the design rests on.
///
/// **A UI-driven run can be stopped.** `progress` is the Actions window's
/// step counter and Stop button; the player consults it between steps, never
/// inside one (a core call cannot be interrupted, and abandoning a half-run
/// filter is worse than finishing it). A stopped run keeps the steps it has
/// already applied and still closes as one undo entry. `run_action` over MCP
/// and Batch pass none — Batch has its own Stop, per file.
enum ActionPlayer {
    // MARK: - Exclusion

    /// True for the whole of `run` / `runSingle`, progress panel included.
    ///
    /// **Why a replay has to be exclusive.** `ActionRunProgress.tick` calls
    /// `NSApp.runModalSession` between steps, and a modal session services
    /// the main run loop in `NSModalPanelRunLoopMode` — one of the modes
    /// libdispatch drains the main QUEUE in. Both agent trampolines reach
    /// `AgentServer.execute` through `DispatchQueue.main.sync`, so an MCP or
    /// assistant tool call really can land between two steps of a UI-driven
    /// replay. It would then run inside `ImageDocument.withReplayUndo`,
    /// which has undo registration disabled and the change count suppressed
    /// for the length of the run: the edit would apply and report `ok`,
    /// register no undo entry of its own, count no change — and the single
    /// snapshot restore the run registers afterwards would revert it along
    /// with the action, so one ⌘Z would silently throw away an edit the user
    /// watched land. It is invisible to the recording too, since the player
    /// suspends `ActionRecorder` for the same window.
    ///
    /// So the whole tool surface is refused while a run is in flight, IN
    /// BAND, the way `start_recording` refuses a second session: a refusal a
    /// model can read and retry is better than an edit that quietly
    /// disappears.
    private(set) static var isPlaying = false

    /// True only while the player's OWN step is inside
    /// `AgentServer.execute` — the one call that must get through.
    private static var isRunningStep = false

    /// The in-band refusal a tool call earns while a replay is in flight,
    /// or nil when it may run. Read by `AgentServer.execute`, which is the
    /// single door every MCP and assistant call comes through.
    static func replayRefusal(tool: String) -> String? {
        guard isPlaying, !isRunningStep else { return nil }
        return "An action is playing on this app — \"\(tool)\" cannot run until it finishes. "
            + "Try again in a moment."
    }

    // MARK: - Running

    /// Plays `action` on `document`. `stopOnError` overrides every step's
    /// own `on_error` when given (Batch's checkbox); nil leaves each step to
    /// its own setting.
    static func run(
        _ action: Action, on document: ImageDocument, stopOnError: Bool? = nil,
        progress: ActionRunProgress? = nil
    ) -> ActionRunReport {
        assert(Thread.isMainThread)
        let server = AgentServer.shared
        let documentID = server.documentID(for: document)
        var report = ActionRunReport(action: action.name)
        report.canvasMismatch = mismatchNote(action, document)

        // A replay is never itself recorded — an action that recorded its own
        // playback would double every step the next time it ran.
        let wasSuspended = ActionRecorder.shared.isSuspended
        ActionRecorder.shared.isSuspended = true
        defer { ActionRecorder.shared.isSuspended = wasSuspended }

        // …and nothing else may edit while it does — see `isPlaying`.
        let wasPlaying = isPlaying
        isPlaying = true
        defer { isPlaying = wasPlaying }

        // The same activity assertion both agent trampolines hold: a run that
        // continues while the app is in the background is user-initiated
        // work, and App Nap would otherwise demote it for the rest of the
        // session (AppActivity.swift).
        AppActivity.userInitiated("playing the \(action.name) action") {
            progress?.begin(action: action.name, steps: action.steps.count)
            defer { progress?.end() }
            document.withReplayUndo(action.name) {
                for (index, step) in action.steps.enumerated() {
                    // The halt is tested FIRST, so nothing after a stop is
                    // counted — not even as skipped, which would read as "we
                    // considered it and passed" rather than "we never got
                    // there".
                    if report.stoppedAt != nil { break }
                    guard step.enabled else {
                        // A disabled step is never a failure; it is simply
                        // not run.
                        report.stepsSkipped += 1
                        continue
                    }
                    // Between steps, never inside one: this both draws the
                    // step counter and services the Stop button, so the app
                    // stays answerable through a long run.
                    guard progress?.tick(step: index + 1) ?? true else {
                        report.cancelled = true
                        report.stoppedAt = index + 1
                        break
                    }
                    guard let reason = runStep(
                        step, on: document, id: documentID, server: server)
                    else {
                        report.stepsRun += 1
                        continue
                    }
                    report.failures.append((step: index + 1, tool: step.tool, reason: reason))
                    // The run-wide override wins over the step's own policy —
                    // that is what Batch's "Stop on error" checkbox means.
                    if stopOnError ?? (step.onError == .stop) {
                        report.stoppedAt = index + 1
                    }
                }
            }
        }
        report.ok = report.failures.isEmpty && !report.cancelled
        return report
    }

    /// Runs ONE step as its own undo entry, under a caller-chosen name —
    /// Filters ▸ Repeat Last (⌃F).
    ///
    /// The rule this call sits on, stated once: **replay inside an Action is
    /// silent (batch semantics); ⌃F is a menu command and ASKS.** The
    /// rasterize prompt therefore happens in the caller
    /// (`EditorViewController.repeatLastFilter`) before this is reached,
    /// exactly as the Filters menu's own path does it — a step run through
    /// the agent dispatch would otherwise rasterize a text layer silently,
    /// which no menu command in the app does.
    static func runSingle(
        _ step: ActionStep, on document: ImageDocument, undoName: String
    ) -> ActionRunReport {
        assert(Thread.isMainThread)
        let server = AgentServer.shared
        let documentID = server.documentID(for: document)
        var report = ActionRunReport(action: undoName)
        let wasSuspended = ActionRecorder.shared.isSuspended
        ActionRecorder.shared.isSuspended = true
        defer { ActionRecorder.shared.isSuspended = wasSuspended }
        let wasPlaying = isPlaying
        isPlaying = true
        defer { isPlaying = wasPlaying }
        AppActivity.userInitiated(undoName) {
            // The same rule as a whole run's (see `run`): one undo entry, and
            // none at all when the repeat changed nothing — a ⌃F that was
            // refused must not leave an "Undo Repeat …" that restores nothing.
            document.withReplayUndo(undoName) {
                if let reason = runStep(step, on: document, id: documentID, server: server) {
                    report.failures.append((step: 1, tool: step.tool, reason: reason))
                    report.stoppedAt = 1
                } else {
                    report.stepsRun = 1
                }
            }
        }
        report.ok = report.failures.isEmpty
        return report
    }

    /// The mark a PLAY leaves in a recording that is running — the one line
    /// every spelling of "play this action" calls, so the three cannot
    /// drift.
    ///
    /// A play is a user-visible command with no usable twin: `run_action`
    /// may not be a step (an action could then name itself and the player
    /// would recurse), so there is nothing to record that would replay.
    /// Recording NOTHING would be the silent hole this feature's recording
    /// rule forbids — the action would look complete and reproduce none of
    /// what the play did — so the gap lands as the same named placeholder
    /// every other twin-less command uses, listed in the Actions window and
    /// refused with its reason at replay.
    ///
    /// It is called after the run and never inside it: the player suspends
    /// the recorder for the length of a replay, so a record made in there
    /// would be dropped.
    static func notePlayed(
        _ action: Action, _ report: ActionRunReport, on document: ImageDocument
    ) {
        guard report.stepsRun > 0 else { return }
        ActionRecorder.shared.record(.unrecorded("Play “\(action.name)”"), on: document)
    }

    /// The document a UI-initiated play targets: the main window's, and
    /// otherwise the front-most document window's.
    ///
    /// The fallback is not a nicety, it is the normal case:
    /// `NSDocumentController.currentDocument` is nil whenever the main window
    /// belongs to no document — which is exactly the state the app is in
    /// while the Actions window is up and its Play button, or File ▸ Automate
    /// ▸ Play, is being used. One implementation so the menu item's
    /// validation, the menu item's action and the window's own button cannot
    /// disagree about whether there is anything to play on.
    static func frontDocument() -> ImageDocument? {
        if let current = NSDocumentController.shared.currentDocument as? ImageDocument {
            return current
        }
        return NSApp.orderedDocuments.compactMap { $0 as? ImageDocument }.first
    }

    // MARK: - One step

    /// Runs one step; nil on success, the failure reason otherwise.
    private static func runStep(
        _ step: ActionStep, on document: ImageDocument, id: Int, server: AgentServer
    ) -> String? {
        guard !step.isUnrecorded else {
            return "\"\(step.unrecordedName)\" was not recorded — it has no MCP tool, so it "
                + "cannot be replayed. Remove or replace this step in the Actions window."
        }
        // Belt to `Action.decode`'s braces: an action that names an Actions
        // tool — or `save_copy`, whose absolute path would escape a batch's
        // output folder — is refused when it is read, so this is unreachable
        // through any path that exists. But `run_action` here would re-enter
        // the player through `AgentServer.execute`, and an action that names
        // itself would recurse until the stack overflowed and the app was
        // killed.
        // A step built in code (where the decode refusal cannot reach, and a
        // release build drops `ActionStep.init`'s assert) fails here instead.
        if let reason = Action.notAStepReason(step.tool) {
            return "\"\(step.tool)\" cannot run inside an action — \(reason)"
        }
        var arguments: [String: Any]
        switch resolve(step.arguments, in: document) {
        case .success(let resolved): arguments = resolved
        case .failure(let error): return error.message
        }
        // Rebound, never recorded: ids are session-scoped integers, so the
        // run's own target is bound here.
        arguments["document_id"] = id
        // `isValidJSONObject` first, for the reason `AgentServer.saveAction`
        // states: `data(withJSONObject:)` RAISES an ObjC exception on a value
        // it cannot write — a non-finite number, most of all — and a raise on
        // this path terminates the process where a `try?` looks like it is
        // handling the failure. `Action.decode` refuses such a value now, so
        // this is the second lock on the same door.
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments)
        else {
            return "this step's arguments could not be encoded as JSON"
        }
        let result = executeStep(
            step.tool, String(decoding: data, as: UTF8.self), server: server)
        return failureMessage(in: result)
    }

    /// The player's own dispatch, marked as such for the length of the call
    /// so the exclusion `isPlaying` describes lets exactly this one through.
    private static func executeStep(
        _ tool: String, _ argumentsJSON: String, server: AgentServer
    ) -> String {
        isRunningStep = true
        defer { isRunningStep = false }
        return server.execute(tool: tool, argumentsJSON: argumentsJSON)
    }

    /// The message out of a CallToolResult that reported `isError`, or nil
    /// when the call succeeded. The tools' own in-band errors are better
    /// than anything the player could write — "A polygon selection needs at
    /// least 3 points" names the fix — so they are lifted verbatim.
    private static func failureMessage(in result: String) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(result.utf8)),
              let object = parsed as? [String: Any]
        else { return "the tool returned a result that could not be read" }
        guard (object["isError"] as? Bool) == true else { return nil }
        let content = object["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
        return text.isEmpty ? "the tool failed" : text
    }

    // MARK: - Symbols

    /// Replaces every symbol in `arguments` with what it names on THIS
    /// document. Recursive, so a symbol inside a `layers` array resolves too.
    private static func resolve(
        _ value: Any, in document: ImageDocument
    ) -> Result<Any, ActionError> {
        if ActionSymbol.looksLikeSymbol(value) {
            switch ActionSymbol.parse(value) {
            case .failure(let error): return .failure(error)
            case .success(let symbol): return resolve(symbol, in: document)
            }
        }
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            for key in object.keys.sorted() {
                switch resolve(object[key] as Any, in: document) {
                case .success(let resolved): out[key] = resolved
                case .failure(let error): return .failure(error)
                }
            }
            return .success(out)
        }
        if let array = value as? [Any] {
            var out: [Any] = []
            for element in array {
                switch resolve(element, in: document) {
                case .success(let resolved): out.append(resolved)
                case .failure(let error): return .failure(error)
                }
            }
            return .success(out)
        }
        return .success(value)
    }

    private static func resolve(
        _ arguments: [String: Any], in document: ImageDocument
    ) -> Result<[String: Any], ActionError> {
        switch resolve(arguments as Any, in: document) {
        case .success(let resolved):
            // Never `?? [:]`: the one value that resolves to something other
            // than a dictionary is a step whose WHOLE arguments object was a
            // symbol, and running that step with no arguments would silently
            // aim it at the wrong layer and report success. `Action.decode`
            // refuses the shape now, so this is the lock on the same door
            // for a step built in code.
            guard let object = resolved as? [String: Any] else {
                return .failure(
                    ActionError(
                        "this step's arguments are a symbol, not an object of named "
                            + "arguments — a symbol is one argument's VALUE, as in "
                            + "{\"layer\": {\"$layer\": \"Sky\"}}"))
            }
            return .success(object)
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func resolve(
        _ symbol: ActionSymbol, in document: ImageDocument
    ) -> Result<Any, ActionError> {
        switch symbol {
        case .activeLayer:
            return .success(document.activeLayerIndex)
        case .layerNamed(let name):
            guard let doc = document.doc else {
                return .failure(ActionError("the document has no image"))
            }
            // TOPMOST match: the layers panel lists top first, so "the layer
            // called Sky" means the one a reader would point at.
            for index in stride(from: doc.layerCount - 1, through: 0, by: -1)
            where doc.layerInfo(index)?.name == name {
                return .success(index)
            }
            return .failure(ActionError("no layer named \"\(name)\""))
        case .selectedLayers:
            let indices = Array(Set(document.selectedLayerIndices)).sorted()
            guard !indices.isEmpty else {
                return .failure(ActionError("this step needs a layer selection; none is set"))
            }
            return .success(indices)
        case .guideAt(let orientation, let position):
            guard let doc = document.doc else {
                return .failure(ActionError("the document has no image"))
            }
            let guides = doc.guides
            // Within half a pixel: the position was written by the same
            // build that reads it, so an exact hit is the normal case and
            // the tolerance only absorbs the JSON round trip.
            for (index, guide) in guides.enumerated()
            where (guide.orientation == .horizontal ? "horizontal" : "vertical") == orientation
                && abs(guide.position - position) <= 0.5
            {
                return .success(index)
            }
            return .failure(
                ActionError(
                    "no \(orientation) guide at \(ActionArgs.number(position)) "
                        + "on this document"))
        }
    }

    /// The one-line warning a size difference earns. Absolute coordinates
    /// are NOT remapped (see `ActionSymbol`), so saying so is the honest
    /// alternative to guessing.
    private static func mismatchNote(_ action: Action, _ document: ImageDocument) -> String? {
        guard let recorded = action.recordedCanvas, let doc = document.doc else { return nil }
        guard recorded.width != doc.width || recorded.height != doc.height else { return nil }
        return "recorded at \(recorded.width) × \(recorded.height), played on "
            + "\(doc.width) × \(doc.height) — absolute coordinates were not remapped"
    }
}

/// What a run did, in the ONE shape the Actions window, `run_action` and
/// Batch's report all read.
struct ActionRunReport {
    var ok: Bool = true
    let action: String
    var stepsRun: Int = 0
    var stepsSkipped: Int = 0
    /// The 1-based step a `stop` policy halted at, if any.
    var stoppedAt: Int?
    /// True when the user pressed Stop. The steps already applied are kept —
    /// they are one undo entry like any other run's — and `stoppedAt` names
    /// the step that never ran.
    var cancelled: Bool = false
    var canvasMismatch: String?
    var failures: [(step: Int, tool: String, reason: String)] = []

    init(action: String) {
        self.action = action
    }

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "ok": ok, "action": action, "steps_run": stepsRun, "steps_skipped": stepsSkipped,
        ]
        if let stoppedAt = stoppedAt { object["stopped_at"] = stoppedAt }
        if cancelled { object["cancelled"] = true }
        if let mismatch = canvasMismatch { object["canvas_mismatch"] = mismatch }
        if !failures.isEmpty {
            object["failures"] = failures.map {
                ["step": $0.step, "tool": $0.tool, "reason": $0.reason]
            }
        }
        return object
    }

    /// The same report as one line of prose, for the Actions window's status
    /// line and Batch's per-file rows.
    func text() -> String {
        var parts = ["\(stepsRun) step\(stepsRun == 1 ? "" : "s")"]
        if stepsSkipped > 0 { parts.append("\(stepsSkipped) skipped") }
        if cancelled {
            parts.append("stopped by you\(stoppedAt.map { " at step \($0)" } ?? "")")
        } else if let stoppedAt = stoppedAt {
            parts.append("stopped at step \(stoppedAt)")
        }
        var line = (ok ? "Ran \(action): " : "\(action): ") + parts.joined(separator: ", ")
        if let failure = failures.first {
            line += " — step \(failure.step) (\(failure.tool)): \(failure.reason)"
            if failures.count > 1 { line += " (+\(failures.count - 1) more)" }
        }
        if let mismatch = canvasMismatch { line += " · \(mismatch)" }
        return line
    }
}
