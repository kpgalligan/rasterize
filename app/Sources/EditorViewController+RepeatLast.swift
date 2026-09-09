import AppKit

/// Filters ▸ Repeat Last Filter (⌃F) — re-run the last destructive filter or
/// adjustment with the same parameters.
///
/// It rides on the recorded-call machinery: `ActionRecorder.lastRepeatable`
/// latches the last step whose tool is in
/// `ActionCatalogFacts.repeatableTools`, WHETHER OR NOT recording is on —
/// which is exactly why that latch lives on the recorder rather than in a
/// recording.
///
/// The item's enablement, its title flip and the ⌃F text-editing guard live
/// in `EditorViewController+Actions.validateActionsItem`, which calls
/// `repeatTitle(for:)` below.
extension EditorViewController {
    /// The rule, stated once and worth stating: **replay inside an Action is
    /// silent (batch semantics); ⌃F is a menu command and ASKS.**
    ///
    /// Running the step naively through the agent dispatch would reach
    /// `performPixelEdit`, whose own contract is that the agent "must never"
    /// put up a modal alert and so rasterizes silently — while the Filters
    /// menu's own path (`performLayerEdit` → `applyToActiveLayer` →
    /// `applyRasterizingEdit`) calls `confirmRasterize` unconditionally. A
    /// naive ⌃F on a text, shape or Live Photo layer would therefore destroy
    /// its description with no prompt, which no menu command in this app
    /// does. So the prompt happens HERE, once, before the step runs.
    @objc func repeatLastFilter(_ sender: Any?) {
        guard let document = document, document.doc != nil,
              let step = ActionRecorder.shared.lastRepeatable
        else {
            // Validation should already have disabled the item; this is the
            // backstop for any path around it.
            NSSound.beep()
            return
        }
        // Aimed at the ACTIVE layer, whatever the latched step named.
        //
        // The latch takes an agent call verbatim, including an explicit
        // `layer` index — the agent said what it meant. A menu command must
        // not: ⌃F on a picture where layer 1 was the agent's target would
        // filter layer 1 while the prompt below asked about layer 0, so a
        // text layer at the recorded index would be rasterized with no prompt
        // at all — which is the one thing this file exists to prevent. The
        // symbol resolves to whatever is active on this document, so the
        // layer the user is looking at is the layer that changes.
        var repeated = step
        repeated.arguments["layer"] = ActionArgs.activeLayer
        repeated.arguments.removeValue(forKey: "index")
        // …and re-aimed at the AMBIENT plane/channel target for the same
        // reason the layer is re-aimed.
        //
        // The latch holds the target the edit was MADE on — the Red plane,
        // an alpha channel — and a menu command must not keep it: the user
        // may since have clicked the composite row in the Channels panel, and
        // a repeat that kept "red" would edit a plane they are no longer
        // pointing at while the menu item read Repeat “Blur” and the layer
        // they aimed at went untouched. `apply_filter` takes a `target`, so
        // it is simply rewritten to the ambient one, exactly as
        // `EditorViewController+Actions.filterRecord` writes it for a fresh
        // filter.
        //
        // The mirror case has no such answer: `auto_tone`, `auto_contrast`
        // and `auto_color` take NO target — they read and write the whole
        // layer — which is precisely why `EditorViewController+AutoAdjust`
        // records them as `.unrecorded` when a plane or a channel is the
        // paint target. Replaying one with a plane selected would stretch all
        // three channels of the whole layer, which is not what Image ▸ Auto
        // Tone would do from the menu, so the repeat is refused with the
        // reason rather than quietly doing the other thing.
        if ActionCatalogFacts.targetedRepeatableTools.contains(repeated.tool) {
            repeated.arguments["target"] = paintTarget.layerEditAgentName(in: document.doc)
        } else if paintTarget.targetsPlaneOrChannel {
            presentRepeatRefusal(
                "“\(Self.repeatName(for: repeated))” cannot be repeated "
                    + "onto “\(paintTarget.agentName(in: document.doc))”",
                detail: "Auto Tone, Auto Contrast and Auto Color read and write a whole "
                    + "layer, so there is no way to repeat one onto a single plane or "
                    + "channel. Run it from the Image ▸ Adjustments menu, which applies it "
                    + "to whatever the Channels panel has selected.")
            return
        }
        guard document.confirmRasterize(layer: document.activeLayerIndex) else { return }
        let report = ActionPlayer.runSingle(
            repeated, on: document, undoName: Self.repeatTitle(for: repeated))
        guard report.ok else {
            presentRepeatFailure(report)
            return
        }
        // ⌃F is a user-visible edit like any other, so it belongs in a
        // recording — and `runSingle` cannot put it there: the player
        // suspends the recorder for the length of EVERY replay, which is
        // right for an action playing itself back and wrong for a menu
        // command that happens to be implemented as one. So the step is
        // recorded here, after the run, when the suspension has been lifted
        // again. Without it a recorded session held the original Gaussian
        // Blur and nothing at all for the ⌃F that repeated it on the next
        // layer — a silent hole, which is the one thing this feature's
        // recording rule forbids. What is recorded is the SYMBOLIC step that
        // just ran ("the active layer"), so it replays where a reader of the
        // action would expect it to.
        ActionRecorder.shared.record([repeated], on: document)
    }

    /// Explains a refused repeat instead of leaving a beep as the only
    /// answer — `presentContentAwareFillFailure`'s shape and its reason: the
    /// refusals a step can hit are specific ("Layer "Sky" is locked", "an
    /// adjustment layer has no pixels to filter") and a beep throws the
    /// sentence away.
    ///
    /// The reason is the TOOL's own in-band message, lifted verbatim by
    /// `ActionRunReport` — the same text an agent would read, and better than
    /// anything this path could invent about a failure it did not diagnose.
    private func presentRepeatFailure(_ report: ActionRunReport) {
        let reason = report.failures.first?.reason ?? "the command could not run"
        // The messages are lowercase sentences meant to follow a "… failed: "
        // lead-in; an alert headline starts one.
        presentRepeatRefusal(
            reason.prefix(1).uppercased() + reason.dropFirst(),
            detail: "Nothing was changed. Repeat Last Filter re-runs the last filter or "
                + "adjustment with the same settings — run it from the Filters or "
                + "Image ▸ Adjustments menu to change them.")
    }

    /// The one alert this command refuses through, whether the step failed or
    /// was never repeatable onto the current target.
    private func presentRepeatRefusal(_ headline: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = headline
        alert.informativeText = detail
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The menu item's title: `Repeat “Sharpen”` when there is something to
    /// repeat, the bare command otherwise. Read by the validation table, and
    /// used as the undo entry's name so Edit ▸ Undo reads what the menu said
    /// rather than the tool it went through.
    static func repeatTitle(for step: ActionStep?) -> String {
        guard let step = step else { return "Repeat Last Filter" }
        return "Repeat “\(repeatName(for: step))”"
    }

    /// What the repeated command is CALLED, the way its own menu spells it.
    ///
    /// Deliberately not `ActionCatalogFacts.displayName` for `apply_filter`:
    /// that names the TOOL and its argument ("Apply Filter: edge_detect"),
    /// which is right in the Actions window — a reader there is looking at
    /// MCP steps — and wrong in a menu, where the user picked an item called
    /// "Edge Detect" and expects to see it again. The other three repeatable
    /// tools (`auto_tone`, `auto_contrast`, `auto_color`) already carry their
    /// own name, so they take the shared spelling unchanged.
    private static func repeatName(for step: ActionStep) -> String {
        if step.tool == "apply_filter", let filter = step.arguments["filter"] as? String,
           !filter.isEmpty
        {
            return filter.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return ActionCatalogFacts.displayName(for: step.tool, arguments: step.arguments)
    }
}
