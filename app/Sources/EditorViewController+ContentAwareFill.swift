import AppKit

/// Edit > Content-Aware Fill…: the command that opens the sheet, and the
/// commit the sheet's Apply calls back into.
///
/// The dialog, its live preview and its parameters are
/// `ContentAwareFillSheetController`; the fill itself is the core's
/// `contentAwareFilled`, shared byte-for-byte with the `content_aware_fill`
/// MCP tool (AgentServer+ContentAwareFill.swift). Nothing about the pixels
/// lives here — this file is the menu route and the one undo step.
extension EditorViewController {
    /// Edit > Content-Aware Fill… — opens the sheet over the current
    /// selection.
    ///
    /// `validateUserInterfaceItem` already disables the item without a
    /// selection, on an adjustment layer, in Quick Mask and with a colour
    /// plane or an alpha channel targeted, but a key equivalent can still
    /// arrive at a disabled item, so every one of those questions is asked
    /// again here. The two that have a sentence to say (an adjustment layer,
    /// a plane or channel target) say it through the shared refusals rather
    /// than a bare beep.
    @objc func contentAwareFill(_ sender: Any?) {
        guard document?.doc != nil, canvas.selection != nil, !canvas.quickMaskActive else {
            NSSound.beep()
            return
        }
        // A fill rewrites the LAYER's own pixels: an adjustment layer has
        // none, and a plane or channel target says an edit lands somewhere
        // else entirely (EditorViewController+Channels' rule, the one Clear
        // and Cut already follow).
        if refuseAdjustmentPixelEdit() { return }
        if refusePlaneTargetEdit() { return }
        presentAsSheet(ContentAwareFillSheetController(editor: self))
    }

    /// The sheet's Apply: one `applyRasterizingEdit`, hence one undo step,
    /// run against the document's CURRENT handle rather than the one the
    /// sheet previewed — the rule every live-preview sheet follows, so an
    /// edit that slipped in while the dialog was open survives.
    ///
    /// `applyRasterizingEdit`, not `applyEdit`: the fill rewrites the layer's
    /// pixels, which contradicts a text, shape or Live Photo description
    /// exactly as a brush stroke does, so the user is asked before the
    /// description is dropped inside the same edit.
    ///
    /// The MASK and the LAYER both come from the sheet, and for one reason:
    /// what Apply commits must be what the sheet previewed. A document-modal
    /// sheet does not stop the main run loop, so an MCP `set_active_layer`,
    /// `select_rect` or `clear_selection` can land while the dialog is up.
    /// Re-reading the active layer here would fill a layer the user never saw
    /// previewed; re-reading the selection was the same bug on the other
    /// axis — the preview filled the ellipse the user drew and Apply filled
    /// whatever rectangle had arrived since, with nothing on screen saying
    /// the committed region was not the previewed one. A captured layer that
    /// no longer exists (it was deleted behind the sheet) is a refusal, not a
    /// silent fallback to a different one, and the same goes for a mask that
    /// no longer matches the document's size.
    ///
    /// `fingerprint` is what makes the first of those true. A range check
    /// cannot: delete layer 0 behind the sheet and index 2 still passes
    /// `index < layerCount`, naming what used to be layer 3 — so Apply filled
    /// a layer the user never saw previewed, in one silent undo step. The
    /// sheet captures `RasterDocument.layerFingerprint` alongside the index
    /// and Apply refuses unless the layer under it still answers the same
    /// thing.
    func applyContentAwareFill(
        layer index: Int, fingerprint: String?, mask: [UInt8], ring: Double,
        sampleAllLayers: Bool, seed: UInt64
    ) {
        guard let document = document, let doc = document.doc,
            mask.count == doc.width * doc.height,
            index >= 0, index < doc.layerCount, !doc.layerIsAdjustment(index)
        else {
            NSSound.beep()
            return
        }
        guard doc.layerFingerprint(index) == fingerprint else {
            presentContentAwareFillFailure(
                "the layer the preview ran on is not the layer at that position any more — "
                    + "it was renamed, moved, or removed while the dialog was open.")
            return
        }
        // `refuseAdjustmentPixelEdit()` is deliberately NOT called here: it
        // asks about the ACTIVE layer, and after the capture above that may
        // be a different one — its alert would then name a layer this fill
        // is not touching. The guard's `layerIsAdjustment(index)` asks the
        // same question about the layer that IS being filled, and the sheet's
        // open path already asked it when the layer was captured.
        // `refusePlaneTargetEdit` stays: a plane or channel target is
        // document state, not a property of any one layer.
        if refusePlaneTargetEdit() { return }
        // The sheet clamps its own field; a non-finite or out-of-range
        // number can only arrive from a caller that is not the sheet, and
        // the core clamps again on its own side.
        let ringPx = ring.isFinite ? Int(min(max(ring, 0), 512).rounded()) : 0
        // The §0.7(a) latch: `applyRasterizingEdit`'s transform cannot
        // throw, yet the core refuses an over-cap selection with a message
        // that names the limit and says what to do about it. Latch it,
        // return nil, and put it in front of the user after the edit path
        // has finished — never `try?`, which would turn a limit with a
        // number in it into a bare beep.
        var thrown: String?
        // The sheet has already dismissed and the preview image been cleared,
        // so from here the app is frozen with nothing to look at until the
        // fill returns — up to the 12.1 s `doc_inpaint`'s module doc measures
        // for the worst call its caps permit. The busy cursor is the only
        // feedback a blocked main thread can still deliver, and the Spot
        // Healing Brush's shorter commit already wears it.
        Self.whileBusy {
            document.applyRasterizingEdit("Content-Aware Fill", layer: index) { current in
                do {
                    return try current.contentAwareFilled(
                        index, mask: mask, ring: ringPx, seed: seed,
                        sampleAllLayers: sampleAllLayers, preview: false)
                } catch let error as RasterCoreError {
                    thrown = error.message
                    return nil
                } catch {
                    thrown = error.localizedDescription
                    return nil
                }
            }
        }
        if let message = thrown { presentContentAwareFillFailure(message) }
    }

    /// Explains a refused fill instead of leaving the beep `applyEdit`
    /// already made as the only answer: the core's refusals are limits with
    /// numbers in them and an instruction ("Select less, or fill it in
    /// pieces"), and a beep throws that away. The sheet has dismissed by the
    /// time this runs, so the alert has the window to itself.
    private func presentContentAwareFillFailure(_ message: String) {
        let alert = NSAlert()
        // The core's messages are lowercase sentences meant to follow a
        // "… failed: " lead-in; an alert headline starts one.
        alert.messageText = message.prefix(1).uppercased() + message.dropFirst()
        alert.informativeText =
            "Nothing was filled: the layer is unchanged and no undo step was added."
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension RasterDocument {
    /// A cheap value that identifies ONE layer well enough for a sheet to
    /// prove, when it commits, that the layer it previewed is still the layer
    /// at that index.
    ///
    /// A document-modal sheet does not stop the main run loop, so an agent's
    /// `delete_layer`, `add_layer` or `reorder_layers` can land behind it and
    /// silently renumber everything above the change. The core has no stable
    /// per-layer identity to ask for, so this is the next best thing: the
    /// stack's height plus everything `layerInfo` knows that a fill does not
    /// itself change — the name and the layer's own box. A rename behind the
    /// sheet therefore also refuses, which is the safe direction to be wrong
    /// in: the user is told the layer moved rather than shown a fill on a
    /// layer they never previewed.
    ///
    /// nil for an index that is out of range, so a deleted top layer refuses
    /// on this test as well as on the range check.
    func layerFingerprint(_ index: Int) -> String? {
        guard let info = layerInfo(index) else { return nil }
        return "\(layerCount)/\(info.offsetX),\(info.offsetY),\(info.width)x\(info.height)/"
            + info.name
    }
}
