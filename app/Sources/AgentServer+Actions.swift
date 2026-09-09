import AppKit

/// The six Actions tools — the MCP mirror of the Actions window and the
/// File ▸ Automate menu.
///
/// Each names the UI path it mirrors, per the parity rule. `start_recording`
/// and `stop_recording` exist so an agent can record a USER's session and
/// hand back the steps, which is the cheapest way to turn "do that again"
/// into something replayable.
///
/// Nothing here re-implements an edit. Every one of these tools moves an
/// Action between three places that already exist — the library on disk
/// (`ActionLibrary`), the recorder (`ActionRecorder`) and the player
/// (`ActionPlayer`) — and the player runs each step through
/// `AgentServer.execute`, the same dispatch this file is an extension of.
/// That is what makes the whole feature affordable: replay needs no second
/// implementation of anything, because every user-visible edit already has
/// an MCP twin.
///
/// Batch has no tool of its own, deliberately: it performs no edit — it is
/// `open_document` + `run_action` + `save_copy` in a loop, and an agent
/// already has all three.
extension AgentServer {
    // MARK: - Reading the library

    /// Mirrors the Actions window's list. With `name`, the whole action.
    func listActions(_ a: [String: Any]) throws -> String {
        if let name = try optionalActionName(a) {
            // `entry`, not `action(named:)`, for the reason `runAction`
            // gives below: a file that will not parse has to answer with WHY
            // rather than with "there is no action of that name".
            switch ActionLibrary.entry(named: name) {
            case .ok(let action)?:
                return try jsonResult(["action": action.jsonObject()])
            case .broken(let file, let reason)?:
                throw ToolError(message: "\(file): \(reason)")
            case nil:
                throw ToolError(message: Self.noSuchAction(name))
            }
        }
        var actions: [[String: Any]] = []
        var broken: [[String: Any]] = []
        // Summaries, not whole actions: a listing shows names and counts, and
        // decoding every recorded stroke's points to produce them is what
        // `Action.decodeSummary` exists to stop.
        for entry in ActionLibrary.summaries() {
            switch entry {
            case .ok(let action):
                var row: [String: Any] = [
                    "name": action.name,
                    "slug": ActionLibrary.slug(for: action.name),
                    "steps": action.stepCount,
                    "disabled_steps": action.disabledSteps,
                ]
                if let canvas = action.recordedCanvas {
                    row["recorded_canvas"] = ["width": canvas.width, "height": canvas.height]
                } else {
                    // Spelled as an explicit null rather than omitted: the
                    // two mean different things to a reader deciding whether
                    // a size mismatch is possible, and a missing key reads
                    // as "the tool forgot".
                    row["recorded_canvas"] = NSNull()
                }
                row["raw"] = action.raw.map { $0.jsonObject() } ?? NSNull()
                if let modified = action.modified {
                    row["modified"] = Self.stamp.string(from: modified)
                }
                actions.append(row)
            case .broken(let file, let reason):
                // Listed, never dropped: an action a user broke by hand has
                // to be visible from here as well as in the window, or the
                // agent's picture of the library silently disagrees with the
                // user's.
                broken.append(["file": file, "reason": reason])
            }
        }
        return try jsonResult(["actions": actions, "broken": broken])
    }

    // MARK: - Running

    /// Mirrors the Actions window's Play button. One undo step for the whole
    /// run (`ActionPlayer`), and the run's report verbatim: a step that
    /// failed reports the tool's OWN in-band message, which names the fix
    /// better than anything this layer could write.
    func runAction(_ a: [String: Any]) throws -> String {
        let name = try requiredActionName(a)
        let document = try target(a)
        // `entry`, not `action(named:)`, so a file that will not parse still
        // answers with the reason it will not parse rather than with "no
        // action of that name" — which is the one thing a user who has just
        // hand-edited it needs to hear.
        let action: Action
        switch ActionLibrary.entry(named: name) {
        case .ok(let decoded)?: action = decoded
        case .broken(let file, let reason)?:
            throw ToolError(message: "\(file): \(reason)")
        case nil:
            throw ToolError(message: Self.noSuchAction(name))
        }
        let report = ActionPlayer.run(
            action, on: document, stopOnError: boolArg(a, "stop_on_error"))
        // The same visible placeholder a UI Play leaves: `run_action` is
        // non-recordable (it would nest a replay), so a recording running
        // over this call would otherwise show nothing where a whole action
        // ran (ActionPlayer.notePlayed).
        ActionPlayer.notePlayed(action, report, on: document)
        var result = report.jsonObject()
        result["document"] = summary(document)
        if action.raw != nil {
            // Said out loud because it is the one part of an action a run
            // does NOT honour: `raw` belongs to the opens BATCH performs, and
            // a document that is already open was developed at open time.
            result["note"] =
                "this action's raw develop settings apply only to the camera RAW files Batch "
                + "opens; a document that is already open was developed when it was opened"
        }
        return try jsonResult(result)
    }

    // MARK: - Writing

    /// Mirrors Stop Recording ▸ name it, and the Actions window's JSON
    /// editor.
    ///
    /// Validation is the FILE's own, not a second copy of it: the steps are
    /// assembled into the object an action file holds and handed to
    /// `Action.decode`, so an unknown tool, a bad `on_error`, a malformed
    /// `{"$layer": …}` and an out-of-range `raw.exposure` are all refused
    /// with the exact sentences a hand-edited file earns — by step index, and
    /// for `raw` through `AgentServer.rawOpenSettings`, the same parser
    /// `open_document` validates its own `raw` object with. Nothing is
    /// written until the whole action decodes.
    ///
    /// `__unrecorded` steps are ACCEPTED here (`Action.isKnownStepTool`) and
    /// refused only at run time: `stop_recording` produces them whenever the
    /// session touched a command with no MCP twin, so refusing them at save
    /// would refuse the app's own recordings.
    ///
    /// `overwrite` replaces an action of the same name; a BROKEN file that
    /// claims the name is not one, and a save lands beside it under the next
    /// free slug rather than destroying a file whose contents nothing here
    /// could read. `delete_action` is how that file goes.
    func saveAction(_ a: [String: Any]) throws -> String {
        let name = try requiredActionName(a)
        guard let steps = a["steps"] as? [Any] else {
            throw ToolError(message: "steps must be an array of step objects")
        }
        let overwrite = boolArg(a, "overwrite") ?? false
        // The SUMMARY, not the whole action: this asks only whether the name
        // is taken, and the file behind it may be a long recorded session.
        if !overwrite, ActionLibrary.summary(named: name) != nil {
            throw ToolError(
                message: "An action named \"\(name)\" already exists — pass overwrite: true "
                    + "to replace it, or choose another name.")
        }
        var object: [String: Any] = [
            "rasterize_action": Action.schemaVersion,
            "name": name,
            "steps": steps.map(Self.withoutDocumentID),
        ]
        if let raw = a["raw"], !(raw is NSNull) { object["raw"] = raw }
        // `isValidJSONObject` first: `data(withJSONObject:)` RAISES rather
        // than throws on a value it cannot write, and while everything here
        // arrives from a parsed JSON request today, a raise would take the
        // app down instead of refusing the call.
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            throw ToolError(message: "steps could not be read as JSON")
        }
        let action: Action
        switch Action.decode(data) {
        case .success(let decoded): action = decoded
        case .failure(let error): throw ToolError(message: error.message)
        }
        let url: URL
        do {
            url = try ActionLibrary.save(action)
        } catch let error as ActionLibrary.Failure {
            throw ToolError(message: error.message)
        }
        var result: [String: Any] = [
            "ok": true,
            "name": action.name,
            "slug": ActionLibrary.slug(for: action.name),
            "path": url.path,
            "steps": action.steps.count,
        ]
        let unrecorded = action.steps.filter { $0.isUnrecorded }.count
        if unrecorded > 0 {
            // Saved, and said: a placeholder is a visible hole, so an agent
            // that just wrote one back unchanged learns now that the action
            // will fail there rather than at the first run.
            result["note"] =
                unrecorded == 1
                ? "one step is an __unrecorded placeholder and will fail when the action runs"
                : "\(unrecorded) steps are __unrecorded placeholders and will fail when the "
                    + "action runs"
        }
        return try jsonResult(result)
    }

    /// Mirrors the Actions window's Delete button.
    ///
    /// A BROKEN file is deletable too, by its file name. `ActionLibrary`
    /// keys every write on a display name, and a file that will not decode
    /// has no display name to key on — so without this, the one action a
    /// user most wants rid of (the one they just broke by hand) would be the
    /// one only the Finder could remove.
    func deleteAction(_ a: [String: Any]) throws -> String {
        let name = try requiredActionName(a)
        switch ActionLibrary.entry(named: name) {
        case .ok?:
            do {
                try ActionLibrary.delete(name)
            } catch let error as ActionLibrary.Failure {
                throw ToolError(message: error.message)
            }
            return try jsonResult(["ok": true, "name": name])
        case .broken(let file, let reason)?:
            // `file` is a `lastPathComponent` read out of the folder, so it
            // can only ever name a file inside it.
            let url = ActionLibrary.directory.appendingPathComponent(file)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw ToolError(
                    message: "could not delete \(file): \(error.localizedDescription)")
            }
            // `ActionLibrary` posts this itself for every write it makes;
            // this one removal goes around it, so the Actions window still
            // hears about it — naming the file, so only its own decode is
            // dropped from the cache.
            ActionLibrary.postDidChange(changed: url)
            return try jsonResult([
                "ok": true, "name": name, "file": file,
                "note": "that file did not parse (\(reason)) — it was deleted, not repaired",
            ])
        case nil:
            throw ToolError(message: Self.noSuchAction(name))
        }
    }

    // MARK: - Recording

    /// Mirrors File ▸ Automate ▸ Start Recording.
    ///
    /// The session records the USER's edits and the agent's alike — the
    /// recorder has exactly one entry point and both feeds reach it — so an
    /// agent can start one, ask the user to do the thing by hand, and stop.
    /// Read-only tools record nothing (`ActionCatalogFacts.nonRecordable`),
    /// and neither does `open_document`, which an agent's session normally
    /// begins with — an action is replayed on a document that already exists,
    /// so a baked-in path would open a second one beside the run's target
    /// (that set's own comment carries the case). A replay is never recorded
    /// either (`ActionPlayer` suspends the recorder for the length of a run),
    /// so an action cannot record its own playback.
    /// A stopped-but-unsaved recording is NOT thrown away silently: starting
    /// a session clears the steps, they live only in memory, and no undo
    /// covers Application Support — so this refuses the way `stop_recording`
    /// refuses a name that is taken, and `discard: true` is the way to say it
    /// on purpose. The UI's own entry point asks the same question in an
    /// alert (`AppDelegate.toggleActionRecording`).
    func startRecording(_ a: [String: Any]) throws -> String {
        let recorder = ActionRecorder.shared
        guard !recorder.isRecording else {
            throw ToolError(message: "Already recording — call stop_recording first.")
        }
        if recorder.hasUnsavedRecording, boolArg(a, "discard") != true {
            let count = recorder.steps.count
            throw ToolError(
                message: "An unsaved recording of \(count) step\(count == 1 ? "" : "s") is "
                    + "still pending — it exists only in memory, and the Actions window's "
                    + "Save Recording button is what keeps it. Pass discard: true to throw "
                    + "it away and start a new one.")
        }
        recorder.start()
        return try jsonResult(["ok": true, "recording": true])
    }

    /// Mirrors File ▸ Automate ▸ Stop Recording. With `name` it saves; without
    /// one it just hands the steps back, which is how an agent inspects a
    /// session before deciding what to keep — the steps come back in the
    /// exact shape `save_action` takes, so keeping them later is one call.
    ///
    /// Every refusal below happens BEFORE the session ends, so a refusal can
    /// never cost the user their recording: the steps are still in the
    /// recorder and a second `stop_recording` with another name saves them.
    func stopRecording(_ a: [String: Any]) throws -> String {
        let recorder = ActionRecorder.shared
        guard recorder.isRecording else {
            throw ToolError(message: "Not recording — call start_recording first.")
        }
        let steps = recorder.steps.map { $0.jsonObject() }
        guard let name = try optionalActionName(a) else {
            recorder.stop()
            return try jsonResult(["ok": true, "saved": false, "steps": steps])
        }
        if ActionLibrary.summary(named: name) != nil {
            throw ToolError(
                message: "An action named \"\(name)\" already exists — still recording, so "
                    + "call stop_recording again with another name, or delete_action first.")
        }
        do {
            try ActionLibrary.save(recorder.recording(named: name))
        } catch let error as ActionLibrary.Failure {
            throw ToolError(message: "\(error.message) — still recording, so nothing was lost")
        }
        recorder.stop()
        // Saved steps are handed over, not kept: the Actions window lists a
        // stopped-but-unsaved recording as its own "Unsaved recording — N
        // steps" row, and leaving them here would offer the same steps twice
        // — once as the action just written, once as a recording still
        // waiting to be saved. This is what the window's own Save Recording
        // button does after a successful save.
        recorder.replaceSteps([])
        return try jsonResult(["ok": true, "saved": true, "name": name, "steps": steps])
    }

    // MARK: - Shared argument handling

    /// The required `name` argument, trimmed.
    private func requiredActionName(_ a: [String: Any]) throws -> String {
        guard let name = try optionalActionName(a) else {
            throw ToolError(message: "Missing required argument: name")
        }
        return name
    }

    /// The optional `name` argument, trimmed — nil ONLY when the key is
    /// genuinely absent.
    ///
    /// A present-but-unusable name (a number, or nothing but spaces) is
    /// refused rather than read as "omitted", because the two mean opposite
    /// things here: without a name `list_actions` lists the whole library and
    /// `stop_recording` ends the session without saving. The trim is what
    /// keeps a name of pure whitespace from reaching disk, where it would
    /// slug to `action` and become a file nothing could name again.
    private func optionalActionName(_ a: [String: Any]) throws -> String? {
        guard let raw = a["name"], !(raw is NSNull) else { return nil }
        guard let text = raw as? String else {
            throw ToolError(message: "name must be a string")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError(message: "name must not be blank")
        }
        return trimmed
    }

    /// One spelling of "there is no such action", so `list_actions`,
    /// `run_action` and `delete_action` all point a caller at the same next
    /// step. `ActionLibrary.delete` writes the same sentence for the same
    /// reason.
    private static func noSuchAction(_ name: String) -> String {
        "No action named \"\(name)\". Call list_actions."
    }

    /// One step with `document_id` removed, the same rule
    /// `ActionRecorder.recordAgentCall` follows for a recorded call: an id is
    /// a session-scoped integer minted by `AgentServer.id(for:)`, the player
    /// rebinds it to whatever document the run targets, and one left in the
    /// file would tell a reader it meant something. Anything that is not a
    /// step object passes through untouched, so `Action.decode` still refuses
    /// it by index ("step 3: not an object").
    private static func withoutDocumentID(_ step: Any) -> Any {
        guard var object = step as? [String: Any],
              var arguments = object["arguments"] as? [String: Any],
              arguments["document_id"] != nil
        else { return step }
        arguments.removeValue(forKey: "document_id")
        object["arguments"] = arguments
        return object
    }

    /// UTC ISO 8601 — the stamp `Action` writes into the file, so a
    /// `modified` read back over MCP is the same string the file holds.
    /// Built once: `ISO8601DateFormatter` is expensive to create and
    /// `list_actions` formats one per row.
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
