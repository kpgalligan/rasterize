import AppKit

/// Red eye, both halves: the tool's drag rectangle (RedEyeSession draws it,
/// this commits it) and Filters > Remove Red Eye, which asks Vision where the
/// eyes are and runs the same core op on each of them. The detection is
/// RedEye.swift; the correction is the core's `rz_doc_red_eye_layer`. Both
/// are mirrored for the agent by `red_eye` and `red_eye_auto`
/// (AgentServer+RedEye.swift).
extension EditorViewController {
    /// The tool's drag rectangle, committed at mouse-up as one undo step.
    ///
    /// A red-eye drag never passes through `onStrokeBegin`, so it never meets
    /// that path's channel refusal — and a `.channel` target is exempt from
    /// `toolReachableTarget`'s coercion, so it survives picking this tool.
    /// Without the guard below the tool would rewrite the photograph while
    /// the status bar, the channel row's ring and both layer wells all name a
    /// channel, which is the bug EditorViewController+Channels documents as
    /// already having been fixed once. The text tool's session refuses in
    /// exactly the same place and for the same reason.
    func redEyeRectDragged(_ rect: CGRect) {
        guard !refuseChannelTargetEdit() else { return }
        guard let document = document, document.doc != nil else {
            NSSound.beep()
            return
        }
        // A canvas drag is outside menu validation's reach, so the adjustment
        // layer is refused here with the alert, exactly as a fill click is.
        guard !refuseAdjustmentPixelEdit() else { return }
        // A GROUP has no pixels of its own, and a lock refuses the correction
        // outright — both said HERE, before `applyRasterizingEdit` asks the
        // user to give up a described layer for a refused edit.
        guard !refuseGroupPixelEdit() else { return }
        let idx = document.activeLayerIndex
        guard !refuseLockedEdit(layer: idx, kind: RZ_EDIT_PIXELS) else { return }
        let options = ToolOptionsStore.shared.redEye
        // The bar's two dials are percentages; the core takes fractions.
        let pupilSize = min(max(options.pupilSize, 1), 100) / 100
        let darken = min(max(options.darken, 0), 100) / 100
        // applyRasterizingEdit, not applyEdit: this rewrites the layer's
        // pixels, so a text, shape or Live Photo layer is asked about first
        // and drops its description inside the same edit. A rectangle with no
        // correctable red in it returns nil and beeps — the refusal
        // convention every canvas gesture already follows, and the eyes were
        // never in question here the way they are on the automatic path.
        document.applyRasterizingEdit(
            "Remove Red Eye", layer: idx,
            record: .redEye(
                rect: rect, pupilSize: options.pupilSize, darken: options.darken)
        ) { doc in
            doc.redEyeLayer(idx, rect: rect, pupilSize: pupilSize, darken: darken)
        }
    }

    /// Filters > Remove Red Eye: Vision's face landmarks locate every eye in
    /// the flattened composite and the same correction runs on each of them,
    /// all in ONE undo step.
    ///
    /// Detection reads the composite — what the user sees — while the
    /// correction rewrites the ACTIVE layer, the same split `selectSubject`
    /// makes. The chain below is §0.7(b)'s pattern and the reason it exists:
    /// `applyEdit` does not compare handles, so `?? doc` alone would hand
    /// back the input handle for a picture whose eyes hold no red and mint an
    /// undo step and a dirty flag for an edit that changed nothing. Returning
    /// nil when the handle never moved is what keeps the no-op honest.
    @objc func removeRedEye(_ sender: Any?) {
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        // Menu validation already disables the item on a plane or channel
        // target and on an adjustment layer; a key equivalent could still
        // arrive, and both refusals are cheap.
        guard !refuseChannelTargetEdit() else { return }
        guard !refuseAdjustmentPixelEdit() else { return }
        guard !refuseGroupPixelEdit() else { return }
        guard !refuseLockedEdit(layer: document.activeLayerIndex, kind: RZ_EDIT_PIXELS)
        else { return }
        let eyes: [RedEye.Eye]
        do {
            eyes = try doc.redEyes()
        } catch {
            presentRedEyeFailure(error)
            return
        }
        let idx = document.activeLayerIndex
        let options = ToolOptionsStore.shared.redEye
        let pupilSize = min(max(options.pupilSize, 1), 100) / 100
        let darken = min(max(options.darken, 0), 100) / 100
        document.applyRasterizingEdit(
            "Remove Red Eye", layer: idx,
            record: .redEyeAuto(
                eyes: eyes, pupilSize: options.pupilSize, darken: options.darken)
        ) { doc in
            var out = doc
            for eye in eyes {
                out = out.redEyeLayer(
                    idx, rect: eye.rect, pupilSize: pupilSize, darken: darken) ?? out
            }
            return out === doc ? nil : out
        }
    }

    /// Explains a refused detection instead of beeping at it: the user asked
    /// for something specific and nothing visible happened, so the reason is
    /// worth a sentence — `presentSubjectFailure`'s shape, and its rule that
    /// a non-`Failure` error degrades to the system's description rather than
    /// being swallowed. The informative text names the manual route, because
    /// "no face was found" is exactly when the tool's rectangle is the
    /// answer.
    private func presentRedEyeFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = (error as? RedEye.Failure)?.message ?? error.localizedDescription
        alert.informativeText =
            "Automatic red-eye removal looks for faces in the flattened image and corrects "
            + "each eye it finds. Nothing was changed. Use the Red Eye tool (P) and drag a "
            + "tight rectangle over one eye to fix it by hand."
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
