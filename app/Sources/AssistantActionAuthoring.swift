import Foundation

/// The assistant's half of Actions: one paragraph spliced into the panel's
/// system prompt.
///
/// Wired into the EXISTING assistant surface rather than a second one — the
/// panel already sees the whole catalog through `AgentServer.catalogJSON()`
/// (`Assistant.swift`), so the six Actions tools join its toolset
/// automatically and nothing here needs a second key gate, a second session
/// or a second view. All this adds is the vocabulary the model cannot infer
/// from the schemas: which symbol spellings exist, that coordinates are not
/// remapped, and that a recording captures the user's own edits too.
///
/// It lives in its own file so the assistant panel's owner and this feature's
/// owner never edit the same lines: the panel's `systemPrompt()` splices this
/// one constant and knows nothing else about Actions.
enum AssistantActionAuthoring {
    /// Spliced into `AssistantPanelViewController.systemPrompt()`.
    ///
    /// Written as one continued line — every line ends in a `\` — because it
    /// is interpolated into the middle of a prompt paragraph, where a stray
    /// newline would read as a section break.
    static let systemPromptSection = """
        You can also build reusable Actions. An Action is a named list of steps; each step \
        is {"tool": <one of your tools>, "arguments": {…}} with document_id omitted — the \
        player rebinds it. Use save_action to create one from a sentence, list_actions to \
        read one back, run_action to play it, delete_action to remove it; start_recording \
        and stop_recording capture what the user does at the keyboard as well as your own \
        calls, so "save what I just did" is a recording rather than a guess. None of those \
        six may be a STEP — an action does not run or edit actions — and neither may \
        save_copy: an action says what to DO to a picture, never where to write it, and \
        Batch chooses the output folder, the format and the name. Nor undo or redo: an \
        action is ONE undo entry, so an undo inside it would destroy the document's redo \
        history and report success. save_action refuses any \
        of the nine by step index. Where a step \
        means "whatever layer is active", write {"$layer": "active"}; for a layer by name \
        write {"$layer": "Sky"}; for the user's current layer selection write \
        {"$layers": "selected"}. Coordinates are absolute canvas pixels and are not \
        remapped, so prefer select_all over a full-canvas select_rect and avoid steps that \
        depend on canvas size when the user wants to batch. Give each step "on_error": \
        "stop" unless the user says otherwise. Pass save_action a "raw" object when the \
        action is meant for batching camera RAW files. The user can then edit the action \
        in the Actions window.
        """
}
