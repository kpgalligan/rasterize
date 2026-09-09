import AppKit

/// An Action: a named, replayable list of MCP tool calls.
///
/// The model and its file format only. Where the steps come from is
/// `ActionSteps.swift` (the recorded vocabulary) and `ActionRecorder`; what
/// running one means is `ActionPlayer`; where they live on disk is
/// `ActionLibrary`.
///
/// An action is a SIDECAR, not document state: nothing here is persisted in
/// a `.rz`, so the phase bumps no `RZDC_VERSION` and the core knows nothing
/// about actions.

/// The one error type this feature reports with: a sentence meant for a
/// human, whether it reaches them through the Actions window, an MCP
/// `isError` reply or a Batch report row.
///
/// It exists because `Result` requires its failure to be an `Error` and the
/// natural spelling here is a bare message — the alternative, conforming
/// `String` to `Error`, would be a module-wide side effect for one feature's
/// convenience.
struct ActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

// MARK: - One step

/// One recorded call: a catalog tool name plus the exact arguments it is
/// replayed with.
///
/// `document_id` never appears — ids are session-scoped integers minted by
/// `AgentServer.id(for:)`, so the player rebinds the argument to whatever
/// document the run targets.
struct ActionStep {
    /// The sentinel tool for a user command that HAS no MCP twin (Paste,
    /// Quick Mask, a ⇧-click Auto-Select, a multi-layer Move drag). It is
    /// not a handler key: it exists so the gap is VISIBLE in the action —
    /// listed in the window, refused with a reason at replay — instead of
    /// being a silent hole in a recording that otherwise looks complete.
    static let unrecordedTool = "__unrecorded"

    /// What a failing step does to the rest of the run. Spelled `continue`
    /// in the file; `continueRun` in Swift, where `continue` is a keyword.
    enum OnError: String {
        case stop
        case continueRun = "continue"
    }

    var tool: String
    var arguments: [String: Any]
    var enabled: Bool
    var onError: OnError
    /// Free text the recorder writes for the reader's benefit — the UI path
    /// this step mirrors, or a caveat (a Move drag records an ABSOLUTE
    /// offset and says so). Ignored on replay.
    var note: String?

    init(
        tool: String, arguments: [String: Any] = [:], enabled: Bool = true,
        onError: OnError = .stop, note: String? = nil
    ) {
        // Sanitised here, once, so `Action.encoded()` cannot fail: every
        // factory builds from JSON primitives already, and a value that is
        // not one would otherwise become an unwritable action file.
        //
        // ASKED before it is done, because doing it is what cost: `jsonSafe`
        // REBUILDS the whole tree, bridging every coordinate to an NSNumber
        // only to hand back the value it was given, and the common case has
        // nothing to fix. Measured on a 10,000-point stroke's arguments:
        // 15.4 ms to rebuild, 4.7 ms to ask. The question is exactly the
        // right one — `isValidJSONObject` documents the same conditions this
        // sanitiser enforces, and was verified to answer false for a NaN, an
        // infinity (nested in an array included), an NSObject, a Date and a
        // CGPoint.
        self.init(
            tool: tool,
            validated: JSONSerialization.isValidJSONObject(arguments)
                ? arguments : ActionStep.jsonSafe(arguments),
            enabled: enabled, onError: onError, note: note)
    }

    /// The DECODE path's init: the arguments are a tree `JSONSerialization`
    /// itself produced and `Action.argumentProblem` has already walked, so
    /// asking `isValidJSONObject` about it would be the same walk a second
    /// time. That second walk was 4.7 ms per 10,000-point stroke — a
    /// twenty-stroke recording paid it twenty times on every load — and it
    /// could never answer anything: a parsed tree holds only JSON primitives,
    /// and the one value in it that `isValidJSONObject` would reject is a
    /// non-finite number, which the walk above refuses by path instead.
    init(
        tool: String, validated arguments: [String: Any], enabled: Bool = true,
        onError: OnError = .stop, note: String? = nil
    ) {
        // The drift guard for a hand-written factory in ActionSteps.swift:
        // nothing enforces that a recorded tool name is a real one, and a
        // typo would only surface when somebody replayed the recording. The
        // same idiom as the startup catalog-parity assert, and possible for
        // the same reason — `AgentServer.handlers` is internal.
        assert(Action.isKnownStepTool(tool), "recorded step names no such tool: \(tool)")
        self.tool = tool
        self.arguments = arguments
        self.enabled = enabled
        self.onError = onError
        self.note = note
    }

    /// True for the `__unrecorded` placeholder, which can never run.
    var isUnrecorded: Bool { tool == Self.unrecordedTool }

    /// The command name an `__unrecorded` placeholder stands for.
    var unrecordedName: String { arguments["action"] as? String ?? "an unrecorded command" }

    /// This step as the JSON object the file holds.
    func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["tool": tool, "arguments": arguments]
        // `enabled` and `on_error` are written only when they differ from
        // the default, so a plain recording reads as a plain list.
        if !enabled { object["enabled"] = false }
        if onError != .stop { object["on_error"] = onError.rawValue }
        if let note = note { object["note"] = note }
        return object
    }

    /// `value` with everything JSONSerialization cannot write removed.
    /// Numbers, strings, booleans, nulls, arrays and string-keyed objects
    /// survive; anything else — and any non-finite number — is dropped
    /// rather than silently written as a description of itself.
    ///
    /// **NSNumber is tested before anything numeric, and the finite check
    /// lives in that case**, because in Swift a `Double`, a `CGFloat` and an
    /// `Int` all satisfy `is NSNumber` — so an `is NSNumber` case ahead of
    /// them (which is what this was) let an infinity straight through and
    /// made the `.isFinite` branches below it dead code. That matters more
    /// than the usual "drop what we cannot write": `JSONSerialization`
    /// RAISES an ObjC exception on a non-finite number rather than throwing,
    /// which no `try?` in Swift can catch, so one infinity in an action's
    /// arguments would terminate the process on the next save, edit or run.
    /// Foundation's own JSON parser produces one from a negative overflow
    /// literal (`-1e999`), so a hand-written action file really can carry it.
    private static func jsonSafe(_ value: Any) -> Any? {
        switch value {
        case is NSNull, is String, is Bool:
            // `is Bool` first, and the value passed through untouched: a
            // JSON boolean is an `__NSCFBoolean` that must stay one.
            return value
        case let number as NSNumber:
            return number.doubleValue.isFinite ? value : nil
        case let array as [Any]:
            return array.compactMap { jsonSafe($0) }
        case let object as [String: Any]:
            return jsonSafe(object)
        default:
            return nil
        }
    }

    private static func jsonSafe(_ object: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in object {
            if let kept = jsonSafe(value) { out[key] = kept }
        }
        return out
    }
}

// MARK: - Symbolic arguments

/// The ENTIRE symbol vocabulary — three forms — that lets a step recorded on
/// one document do the analogous thing on another.
///
/// A symbol is a JSON object with exactly one key, beginning `$`. Anything
/// else is a literal, so a caller's own `{"$layer": …}`-shaped data (there is
/// none in the catalog today) could never be misread as one.
///
/// What is deliberately NOT symbolic: canvas geometry (x, y, width, points,
/// offsets, guide positions) is recorded as ABSOLUTE canvas pixels and
/// replayed literally. Proportional remapping is right for a crop and wrong
/// for a 12 px text baseline, and guessing which is which is how an Action
/// silently produces a picture nobody asked for. `Action.recordedCanvas`
/// carries the size it was recorded at so the player can SAY the sizes
/// differ. Select All is the one case where that would have been a real
/// trap, and it is fixed at the source: it records `select_all`, which is
/// canvas-relative by construction.
enum ActionSymbol {
    /// `{"$layer": "active"}` — whatever layer is active on the replay
    /// document. Cannot fail.
    case activeLayer
    /// `{"$layer": "Sky"}` — the TOPMOST layer with that exact name.
    case layerNamed(String)
    /// `{"$layers": "selected"}` — the replay document's layer selection,
    /// sorted and duplicate-free (`AgentServer.layerIndices` refuses
    /// duplicates and sorts, so the recorder must not hand it anything else).
    case selectedLayers
    /// `{"$guide": {"orientation": "horizontal", "position": 412}}` — the
    /// guide at that position, resolved to a live index at replay. Recording
    /// the positional index instead would delete a DIFFERENT guide after any
    /// earlier guide edit in the same action.
    case guideAt(orientation: String, position: Double)

    /// True when `value` has a symbol's SHAPE — one key, beginning `$` —
    /// whether or not its contents parse. Shape and validity are separate so
    /// a malformed symbol is refused by name instead of being read as a
    /// literal dictionary.
    static func looksLikeSymbol(_ value: Any) -> Bool {
        guard let object = value as? [String: Any], object.count == 1,
              let key = object.keys.first
        else { return false }
        return key.hasPrefix("$")
    }

    /// Parses a symbol-shaped object, or returns the reason it is not one of
    /// the three forms — the text that becomes part of a decode refusal.
    static func parse(_ value: Any) -> Result<ActionSymbol, ActionError> {
        guard let object = value as? [String: Any], let key = object.keys.first,
              let payload = object[key]
        else {
            return .failure(ActionError("a symbol must be an object with one $-prefixed key"))
        }
        switch key {
        case "$layer":
            guard let name = payload as? String, !name.isEmpty else {
                return .failure(ActionError("$layer must be \"active\" or a layer name"))
            }
            return .success(name == "active" ? .activeLayer : .layerNamed(name))
        case "$layers":
            guard let which = payload as? String, which == "selected" else {
                return .failure(ActionError("$layers must be \"selected\""))
            }
            return .success(.selectedLayers)
        case "$guide":
            guard let fields = payload as? [String: Any],
                  let orientation = fields["orientation"] as? String,
                  orientation == "horizontal" || orientation == "vertical",
                  let position = (fields["position"] as? NSNumber)?.doubleValue,
                  position.isFinite
            else {
                return .failure(
                    ActionError(
                        "$guide must be an object with \"orientation\" (\"horizontal\" or "
                            + "\"vertical\") and a numeric \"position\""))
            }
            return .success(.guideAt(orientation: orientation, position: position))
        default:
            return .failure(ActionError("unknown symbol \"\(key)\""))
        }
    }

    /// This symbol as the JSON object a step holds.
    var jsonObject: [String: Any] {
        switch self {
        case .activeLayer: return ["$layer": "active"]
        case .layerNamed(let name): return ["$layer": name]
        case .selectedLayers: return ["$layers": "selected"]
        case .guideAt(let orientation, let position):
            return ["$guide": ["orientation": orientation, "position": position]]
        }
    }
}

// MARK: - The action

/// A named list of steps, plus the two things a replay needs to know about
/// the session that produced it.
struct Action {
    /// The schema version this build writes. A reader refuses an unknown one
    /// by name rather than guessing at a newer shape.
    static let schemaVersion = 1

    /// The display name, and the authority: the file name is only a slug of
    /// it (`ActionLibrary.slug`).
    var name: String
    var steps: [ActionStep]
    /// The canvas the recording was made on. REPORTED on a size mismatch,
    /// never used to remap a coordinate — see `ActionSymbol`.
    var recordedCanvas: (width: Int, height: Int)?
    /// The develop settings Batch opens camera RAW files with. Nil is "as
    /// shot". It belongs to the ACTION and not to a step because Batch does
    /// the opening itself; an `open_document` step inside an action carries
    /// its own `raw` in its own arguments and Batch never touches it.
    var raw: RawDevelopSettings?
    var created: Date?
    var modified: Date?

    init(
        name: String, steps: [ActionStep], recordedCanvas: (width: Int, height: Int)? = nil,
        raw: RawDevelopSettings? = nil, created: Date? = nil, modified: Date? = nil
    ) {
        self.name = name
        self.steps = steps
        self.recordedCanvas = recordedCanvas
        self.raw = raw
        self.created = created
        self.modified = modified
    }

    /// The Actions machinery's own tools, and the one tool that writes a
    /// file: a STEP may never name any of them.
    ///
    /// `run_action` is the one that matters: it is a live dispatch key, so
    /// without this an action could name itself (or two could name each
    /// other) and the player would recurse — `ActionPlayer.run` →
    /// `AgentServer.execute` → `runAction` → `ActionPlayer.run` — until the
    /// stack overflowed and the app was killed, taking every open document's
    /// unsaved work with it. The other five are here for coherence rather
    /// than for safety: an action that records, saves or deletes actions
    /// while it runs edits the library out from under the run.
    ///
    /// **`save_copy` is here for containment.** A step's path is an
    /// ABSOLUTE one recorded when the action was written, and Batch's own
    /// guards — the output-folder identity test, the `claimed` set, the
    /// exists/overwrite check — cover only the destination Batch computes.
    /// So a single `save_copy` step ran over a folder of 300 files wrote 300
    /// times to that one path, outside the output folder the user chose,
    /// with every report row still reading `ok`; aimed at a file in the INPUT
    /// folder it destroyed that input on the first file and rewrote it 299
    /// times. Batch does the saving — it owns the folder, the format and the
    /// naming rule — and an action says only what to DO to the picture.
    ///
    /// **`undo` and `redo` are here because an action IS one undo entry.**
    /// `ImageDocument.withReplayUndo` disables undo registration for the
    /// whole run, so the redo registration `restoreDoc` makes while
    /// NSUndoManager is undoing is dropped on the floor: measured, an action
    /// whose single step was `undo` reported `ok`, removed the top layer and
    /// left "Nothing to redo" behind, while the identical `undo` tool called
    /// directly kept redo working. The same bracket also swallows
    /// `restoreDoc`'s `.changeUndone`, so the run left the change count one
    /// edit high for a run whose net effect was an undo. Neither is
    /// something a step can be made to do correctly — an entry cannot
    /// contain itself — so the pair is refused by name, which is also what
    /// the assistant's prompt paragraph tells a model.
    ///
    /// Refused at DECODE time, so a hand-edited file, `save_action` and the
    /// window's JSON editor all report it by step index instead of writing a
    /// file that crashes the app, or overwrites someone's originals, the
    /// moment anything runs it. `ActionCatalogFacts.nonRecordable` already
    /// keeps all nine out of a recording; this is the half that keeps them
    /// out of a file.
    static let notAStepTool: Set<String> = [
        "list_actions", "run_action", "save_action", "delete_action",
        "start_recording", "stop_recording", "save_copy", "undo", "redo",
    ]

    /// Why `tool` may not be a step, in a sentence that goes on the end of
    /// `"step N: \"tool\" cannot be a step — "`; nil when it may.
    ///
    /// Three reasons, kept apart because a reader who is told the wrong one
    /// goes looking for the wrong fix.
    static func notAStepReason(_ tool: String) -> String? {
        guard notAStepTool.contains(tool) else { return nil }
        if tool == "undo" || tool == "redo" {
            return "an action is ONE undo entry, so its steps' own registrations are "
                + "suppressed while it runs — an undo inside it would throw the document's "
                + "redo history away and report success. Undo the whole action instead"
        }
        guard tool == "save_copy" else {
            return "an action may not run, record or edit actions"
        }
        return "an action may not write files. Its path would be the absolute one "
            + "recorded here, so every file a batch touched would be written over the "
            + "same one, outside the output folder — Batch chooses the folder, the "
            + "format and the name"
    }

    /// True for a tool a step may name: a live dispatch key that is not one
    /// of the Actions tools, or the `__unrecorded` placeholder.
    ///
    /// The placeholder has to be whitelisted here rather than refused at
    /// load: `stop_recording` produces steps containing it whenever the
    /// session touched a command with no twin, so a validator that rejected
    /// it would refuse the app's own recordings. The refusal belongs at RUN
    /// time, where it can name the command that was not recorded.
    static func isKnownStepTool(_ tool: String) -> Bool {
        guard !notAStepTool.contains(tool) else { return false }
        return tool == ActionStep.unrecordedTool || AgentServer.handlers.keys.contains(tool)
    }

    /// This action as a LISTING sees it — what `Action.decodeSummary` would
    /// have produced from the same file, so a decode the app already holds
    /// can seed the summary cache instead of being re-read out of it.
    var summary: ActionSummary {
        ActionSummary(
            name: name, stepCount: steps.count,
            disabledSteps: steps.filter { !$0.enabled }.count,
            recordedCanvas: recordedCanvas,
            // The summary mirrors the FILE, and `encoded()` omits an as-shot
            // develop entirely, so a decode of those bytes reports nil.
            raw: (raw?.isAsShot ?? true) ? nil : raw, created: created, modified: modified)
    }

    /// The whole action as the JSON object its file holds.
    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "rasterize_action": Self.schemaVersion,
            "name": name,
            "steps": steps.map { $0.jsonObject() },
        ]
        if let canvas = recordedCanvas {
            object["recorded_canvas"] = ["width": canvas.width, "height": canvas.height]
        }
        if let raw = raw, !raw.isAsShot { object["raw"] = raw.jsonObject() }
        if let created = created { object["created"] = Self.stamp.string(from: created) }
        if let modified = modified { object["modified"] = Self.stamp.string(from: modified) }
        return object
    }

    /// Past this many bytes an action is written compactly instead of
    /// pretty-printed.
    ///
    /// Pretty-printing is for the reader — the JSON editor, a diff — and a
    /// file this size has no reader: it is a recorded paint session, and the
    /// bulk of it is `[[x, y], …]` arrays that the printer puts on one line
    /// each. Measured: the same 150-stroke recording is 34.7 MB compact and
    /// 124.4 MB pretty-printed, and every Enabled toggle in the Actions
    /// window rewrites the whole file. 256 KB is well past any action a
    /// person would edit by hand and well below where the formatting starts
    /// to cost seconds.
    private static let prettyPrintLimit = 256 * 1024

    /// The bytes written to disk: sorted keys always — so re-saving an
    /// untouched action rewrites the same bytes — and pretty-printed while
    /// the result is small enough to be worth reading.
    func encoded() -> Data {
        let object = jsonObject()
        // `isValidJSONObject` first, exactly as `AgentServer.saveAction`
        // does: `data(withJSONObject:)` RAISES on a value it cannot write
        // rather than throwing, and a raise here — on a save, a reorder, an
        // Enabled toggle — would take the app down. `ActionStep.jsonSafe`
        // already makes that unreachable; this is the belt to its braces.
        guard JSONSerialization.isValidJSONObject(object),
              let compact = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
        else {
            // Unreachable: `ActionStep.init` sanitises arguments to JSON
            // primitives, and every other field is a String, Int or Bool. An
            // empty object is still a decodable file that reports its own
            // problem ("rasterize_action is missing") rather than a truncated
            // one.
            return Data("{}".utf8)
        }
        guard compact.count <= Self.prettyPrintLimit,
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return compact }
        return pretty
    }

    /// Parses one action file. The failure is the exact sentence shown to
    /// the user — in the Actions window beside a greyed entry, or as the
    /// in-band error of `save_action` / `run_action` — so every one of them
    /// names what is wrong and where.
    ///
    /// This is the FULL read, and it is not what a listing wants: see
    /// `decodeSummary`, which shares every check below but the one that walks
    /// a step's arguments.
    static func decode(_ data: Data) -> Result<Action, ActionError> {
        let envelope: Envelope
        switch Self.envelope(data) {
        case .success(let parsed): envelope = parsed
        case .failure(let reason): return .failure(reason)
        }
        var steps: [ActionStep] = []
        steps.reserveCapacity(envelope.rawSteps.count)
        for (index, entry) in envelope.rawSteps.enumerated() {
            switch decodeStep(entry, at: index) {
            case .success(let step): steps.append(step)
            case .failure(let reason): return .failure(reason)
            }
        }
        var action = Action(name: envelope.name, steps: steps)
        switch settings(envelope.object) {
        case .success(let settings):
            action.recordedCanvas = settings.canvas
            action.raw = settings.raw
            action.created = settings.created
            action.modified = settings.modified
        case .failure(let reason):
            return .failure(reason)
        }
        return .success(action)
    }

    /// Everything about a file EXCEPT its steps' arguments: the name, the
    /// step count, how many are disabled, and the three trailing fields.
    ///
    /// **The listing paths read this and never the whole thing.** A recorded
    /// paint session is almost entirely `[[x, y], …]`, and decoding those
    /// arrays to answer "what is this action called?" was the app's worst
    /// stall: measured on ten 3.1 MB recordings (one recorder budget each —
    /// 200,000 points), the first `ActionLibrary.load()` after launch cost
    /// **6.50 s of main-thread time** and left **186 MB** of decoded points
    /// resident for the life of the process. That load is reached from
    /// `validateMenuItem` every time File ▸ Automate opens, from the Actions
    /// window on every recorded step, and from the command palette — so a
    /// user with ten saved recordings beachballed on the first menu click
    /// after every launch. Nothing in a listing reads an argument.
    ///
    /// Every check a listing can afford is still made — the JSON shape, the
    /// schema version, the name, and each step's object shape and tool name
    /// — so a hand-edit that breaks any of those is still listed as broken,
    /// with its reason, exactly as before. What moves to the full read is the
    /// deep argument walk: a bad symbol or a non-finite number now reports
    /// itself when the action is selected, run or edited rather than in the
    /// pop-up, which is the one place it can name the step and the path
    /// anyway.
    static func decodeSummary(_ data: Data) -> Result<ActionSummary, ActionError> {
        let envelope: Envelope
        switch Self.envelope(data) {
        case .success(let parsed): envelope = parsed
        case .failure(let reason): return .failure(reason)
        }
        var summary = ActionSummary(name: envelope.name, stepCount: envelope.rawSteps.count)
        for (index, entry) in envelope.rawSteps.enumerated() {
            switch stepShape(entry, at: index) {
            case .success(let shape): if !shape.enabled { summary.disabledSteps += 1 }
            case .failure(let reason): return .failure(reason)
            }
        }
        switch settings(envelope.object) {
        case .success(let settings):
            summary.recordedCanvas = settings.canvas
            summary.raw = settings.raw
            summary.created = settings.created
            summary.modified = settings.modified
        case .failure(let reason):
            return .failure(reason)
        }
        return .success(summary)
    }

    /// The parsed file with its steps still unwalked — what both reads start
    /// from, so the version, name and `steps` refusals are written once.
    private struct Envelope {
        let object: [String: Any]
        let name: String
        let rawSteps: [Any]
    }

    private static func envelope(_ data: Data) -> Result<Envelope, ActionError> {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any]
        else {
            return .failure(ActionError("not a JSON object"))
        }
        guard let version = (object["rasterize_action"] as? NSNumber)?.intValue else {
            return .failure(ActionError("rasterize_action is missing"))
        }
        guard version == schemaVersion else {
            return .failure(
                ActionError(
                    "unknown rasterize_action version \(version) "
                        + "(this build reads \(schemaVersion))"))
        }
        guard let name = object["name"] as? String, !name.isEmpty else {
            return .failure(ActionError("name is missing or not a string"))
        }
        guard let rawSteps = object["steps"] as? [Any] else {
            return .failure(ActionError("steps is not an array"))
        }
        return .success(Envelope(object: object, name: name, rawSteps: rawSteps))
    }

    /// The three trailing fields both reads carry, in one place so the `raw`
    /// refusals cannot drift between them.
    private static func settings(
        _ object: [String: Any]
    ) -> Result<
        (canvas: (width: Int, height: Int)?, raw: RawDevelopSettings?, created: Date?,
         modified: Date?), ActionError
    > {
        var canvas: (width: Int, height: Int)?
        if let recorded = object["recorded_canvas"] as? [String: Any],
           let width = (recorded["width"] as? NSNumber)?.intValue,
           let height = (recorded["height"] as? NSNumber)?.intValue,
           width > 0, height > 0
        {
            canvas = (width: width, height: height)
        }
        var raw: RawDevelopSettings?
        if object["raw"] != nil {
            // The SAME parser and the same strict range refusals as
            // open_document's `raw` object, so "raw.exposure must be between
            // -4 and 4 (got 9)" reads identically wherever it is refused.
            do {
                raw = try AgentServer.shared.rawOpenSettings(object)
            } catch let error as AgentServer.ToolError {
                return .failure(ActionError(error.message))
            } catch {
                return .failure(
                    ActionError("raw could not be read: \(error.localizedDescription)"))
            }
        }
        return .success(
            (canvas: canvas, raw: raw,
             created: (object["created"] as? String).flatMap { stamp.date(from: $0) },
             modified: (object["modified"] as? String).flatMap { stamp.date(from: $0) }))
    }

    /// The O(1)-per-step half of a step's decode: that it is an object, that
    /// it names a tool a step may be, and its `enabled` flag read leniently.
    ///
    /// Shared so a listing and a full decode agree about what a BROKEN file
    /// is. `enabled` is read strictly by `decodeStep` below, after the
    /// arguments, which keeps the reported failure the first one a reader
    /// would look for; a summary only counts, so it takes the lenient answer.
    private static func stepShape(
        _ entry: Any, at index: Int
    ) -> Result<(object: [String: Any], tool: String, enabled: Bool), ActionError> {
        let label = "step \(index + 1)"
        guard let object = entry as? [String: Any] else {
            return .failure(ActionError("\(label): not an object"))
        }
        guard let tool = object["tool"] as? String else {
            return .failure(ActionError("\(label): tool is missing or not a string"))
        }
        // Named before the generic refusal so the reason is the real one:
        // these ARE live tools, and "unknown tool" would send a reader
        // looking for a typo.
        if let reason = notAStepReason(tool) {
            return .failure(
                ActionError("\(label): \"\(tool)\" cannot be a step — \(reason)"))
        }
        guard isKnownStepTool(tool) else {
            return .failure(ActionError("\(label): unknown tool \"\(tool)\""))
        }
        return .success((object: object, tool: tool, enabled: object["enabled"] as? Bool ?? true))
    }

    private static func decodeStep(
        _ entry: Any, at index: Int
    ) -> Result<ActionStep, ActionError> {
        let label = "step \(index + 1)"
        let object: [String: Any]
        let tool: String
        switch stepShape(entry, at: index) {
        case .success(let shape): (object, tool) = (shape.object, shape.tool)
        case .failure(let reason): return .failure(reason)
        }
        var arguments: [String: Any] = [:]
        if let raw = object["arguments"], !(raw is NSNull) {
            guard let parsed = raw as? [String: Any] else {
                return .failure(ActionError("\(label): arguments is not an object"))
            }
            arguments = parsed
        }
        // A symbol names ONE argument's value. The whole `arguments` object is
        // not one, and the shape is plausible enough to be written by hand or
        // by a model reading the symbol docs — so it is refused here rather
        // than resolved: the player would resolve it to a layer INDEX, fail
        // to read that as a dictionary and run the step with no arguments at
        // all, which for a tool whose arguments are all optional
        // (`auto_tone`, `flatten_image`) looks like a clean success on the
        // wrong layer.
        if ActionSymbol.looksLikeSymbol(arguments) {
            return .failure(
                ActionError(
                    "\(label): arguments must be an object of named arguments, not a "
                        + "symbol — a symbol is one argument's VALUE, as in "
                        + "{\"layer\": {\"$layer\": \"Sky\"}}"))
        }
        if let problem = argumentProblem(arguments) {
            return .failure(ActionError("\(label): \(problem.message)"))
        }
        var onError = ActionStep.OnError.stop
        if let raw = object["on_error"], !(raw is NSNull) {
            guard let text = raw as? String, let parsed = ActionStep.OnError(rawValue: text)
            else {
                return .failure(
                    ActionError(
                        "\(label): on_error must be \"stop\" or \"continue\" "
                            + "(got \(quoted(object["on_error"])))"))
            }
            onError = parsed
        }
        var enabled = true
        if let raw = object["enabled"], !(raw is NSNull) {
            guard let flag = raw as? Bool else {
                return .failure(ActionError("\(label): enabled must be true or false"))
            }
            enabled = flag
        }
        return .success(
            ActionStep(
                tool: tool, validated: arguments, enabled: enabled, onError: onError,
                note: object["note"] as? String))
    }

    /// Every symbol-shaped value in `arguments`, and every number, checked at
    /// LOAD time so a hand-edited `{"$layer": 3}` is refused with its path
    /// rather than failing halfway through a replay that has already changed
    /// the picture. Recursive, because a symbol may sit inside an array (a
    /// layer set) — there is nowhere in the catalog it can sit deeper than
    /// that today, and walking anyway costs nothing and cannot go stale.
    ///
    /// A non-finite number is refused HERE rather than dropped by
    /// `ActionStep.jsonSafe`, which would leave the step decoding cleanly
    /// with the key silently missing. Foundation's JSON parser turns a
    /// negative overflow literal (`-1e999`) into −infinity, so this is a
    /// value a hand-written file really can hold — and one that no
    /// `JSONSerialization` write can survive.
    ///
    /// **The path is assembled on the way OUT, never on the way in**, which
    /// is what makes the walk affordable. Interpolating `"\(path).\(key)"`
    /// and `"\(path)[\(index)]"` at every node built three strings per
    /// recorded point and was almost the whole cost of loading an action: a
    /// 3.1 MB recording of 200,000 stroke points took 2.34 s to decode, of
    /// which ~2.2 s was this formatting, for a string that is thrown away at
    /// every node but the one that fails.
    private struct ArgumentProblem {
        /// The failure, as a suffix that follows the path: " is not a finite
        /// number", or ": " and a symbol parser's own sentence.
        let suffix: String
        /// The path back up to `arguments`, INNERMOST FIRST — components are
        /// appended as the failure unwinds, and reversed to read it.
        var path: [String] = []

        var message: String { "arguments" + path.reversed().joined() + suffix }
    }

    private static func argumentProblem(_ value: Any) -> ArgumentProblem? {
        if let number = value as? NSNumber, !(value is Bool), !number.doubleValue.isFinite {
            return ArgumentProblem(suffix: " is not a finite number")
        }
        if ActionSymbol.looksLikeSymbol(value) {
            // The `arguments` object being symbol-shaped is `decodeStep`'s
            // own refusal — it is the one case with nothing to name — so a
            // symbol reached here is a value, and either parses or says why.
            if case .failure(let error) = ActionSymbol.parse(value) {
                return ArgumentProblem(suffix: ": \(error.message)")
            }
            return nil
        }
        if let object = value as? [String: Any] {
            // Sorted so the reported failure is the same one every time the
            // file is loaded, whatever order the dictionary hashes in.
            for key in object.keys.sorted() {
                if var problem = argumentProblem(object[key] as Any) {
                    problem.path.append(".\(key)")
                    return problem
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for (index, element) in array.enumerated() {
                if var problem = argumentProblem(element) {
                    problem.path.append("[\(index)]")
                    return problem
                }
            }
        }
        return nil
    }

    private static func quoted(_ value: Any?) -> String {
        guard let text = value as? String else { return "\(value ?? "nothing")" }
        return "\"\(text)\""
    }

    /// ISO 8601 in UTC, for `created` and `modified`. Both are optional on
    /// read: a hand-written action need not carry either.
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

/// What a library file turned out to be: something readable, or a file that
/// could not be read AND the reason. A broken file is listed and greyed
/// rather than silently dropped — a user who hand-edits an action must be
/// able to see what they broke.
///
/// Generic over what "readable" means, because the library answers two
/// different questions with the same shape: a listing wants an
/// `ActionSummary` and a run wants the whole `Action`.
enum ActionEntry<Value> {
    case ok(Value)
    case broken(file: String, reason: String)
}

/// One entry of the library, fully decoded.
typealias ActionLoadResult = ActionEntry<Action>

/// One entry of the library as a LISTING sees it.
typealias ActionSummaryResult = ActionEntry<ActionSummary>

/// What an action is, minus its steps: everything a listing shows.
///
/// It exists so opening a menu never walks a recorded polyline — the whole
/// argument is in `Action.decodeSummary`. Everything here is either a header
/// field or a count taken from the top level of the `steps` array, so
/// producing one costs the JSON parse and nothing per point.
struct ActionSummary {
    var name: String
    var stepCount: Int
    var disabledSteps: Int = 0
    var recordedCanvas: (width: Int, height: Int)?
    var raw: RawDevelopSettings?
    var created: Date?
    var modified: Date?
}

extension RawDevelopSettings {
    /// True when nothing is set — the develop request that means "as shot",
    /// which is written as no `raw` object at all.
    var isAsShot: Bool { self == RawDevelopSettings() }

    /// The develop request as the JSON object `open_document`'s `raw`
    /// argument and an action file both use, so the two spellings cannot
    /// drift: the keys here are exactly the ones `AgentServer.rawOpenSettings`
    /// parses.
    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [:]
        if let value = exposure { object["exposure"] = value }
        if let value = temperature { object["temperature"] = value }
        if let value = tint { object["tint"] = value }
        if let value = toneCurve { object["tone_curve"] = value }
        if let value = shadows { object["shadows"] = value }
        if let value = contrast { object["contrast"] = value }
        if let value = sharpness { object["sharpness"] = value }
        if let value = detail { object["detail"] = value }
        if let value = luminanceNoise { object["luminance_noise"] = value }
        if let value = colorNoise { object["color_noise"] = value }
        if let value = lensCorrection { object["lens_correction"] = value }
        if let value = highlightRecovery { object["highlight_recovery"] = value }
        return object
    }
}
