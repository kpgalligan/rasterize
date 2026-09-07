import AppKit

/// The Patch tool's commit: the one seam between the canvas's drag
/// (PatchSession, which owns the outline, the move and the on-canvas
/// feedback) and the core's Poisson heal.
///
/// The whole gesture is ONE undo step, and it is the drag's release that
/// makes it: nothing is written while the region is being moved — the drag
/// draws its preview and touches no pixels — so the single
/// `applyRasterizingEdit` below is the edit. The overlay it hands the core is
/// the Clone Stamp's currency (canvas-sized, premultiplied, alpha =
/// coverage, RGB = the already aligned source), built by
/// `PatchSession.buildOverlay` — the same call `patch_region` makes, so the
/// tool and the agent cannot drift apart on the geometry.
extension EditorViewController {
    /// The pixels a patch takes with Sample All Layers OFF: the active
    /// layer's own, already placed in canvas space and transparent
    /// elsewhere, tagged with the document's own space so the sampled
    /// numbers move unconverted (a sampled colour converts nowhere). nil
    /// means the canvas's composite — the option is on, or there is nothing
    /// to sample.
    ///
    /// `strokeSourceImage`'s twin (EditorViewController+Heal), and it exists
    /// for the same reason: the option picks a SNAPSHOT and nothing else. The
    /// canvas asks for it when a region is placed so the drag's feedback
    /// draws the pixels this file's commit will take; showing the composite
    /// while healing from the layer underneath it was a preview of something
    /// that could not happen.
    func patchSourceImage() -> CGImage? {
        guard !ToolOptionsStore.shared.patch.sampleAllLayers,
            let document = document, let doc = document.doc
        else { return nil }
        return doc.layerCanvasImage(document.activeLayerIndex)?
            .makeCGImage(in: doc.colorSpace)
    }

    /// Heals the dragged region, taking texture from where it was dragged to
    /// (direction Source) or carrying its own texture onto where it was
    /// dragged (direction Destination).
    func patchCommitted(_ result: PatchSession.Result) {
        // FIRST, before anything reads a pixel. `toolReachableTarget`
        // deliberately exempts a `.channel` target from coercion — a channel
        // is document state, not a property of the layer this tool rewrites,
        // so its row stays selected whatever tool is picked — and this commit
        // never passes through `onStrokeBegin`, which is where a clone, dodge
        // or healing STROKE is refused on a channel. Without this line the
        // patch would rewrite the photograph while the status bar, the
        // channel row's ring and both layer wells all name a channel
        // (EditorViewController+Channels documents that bug; the text
        // session's commit guards itself the same way).
        guard !refuseChannelTargetEdit() else { return }
        // The canvas-click paths are outside menu validation's reach, so the
        // adjustment-layer refusal is spoken here, in the same alert fill and
        // gradient use — and the agent mirror throws the same sentence.
        guard !refuseAdjustmentPixelEdit() else { return }
        // A GROUP has no pixels of its own (`heal_layer` goes through the
        // core's `raster_layer`), and a lock refuses the heal outright —
        // both said HERE, before `applyRasterizingEdit` asks the user to give
        // up a described layer for an edit that is about to be refused. The
        // MCP mirror answers the same two sentences.
        guard !refuseGroupPixelEdit() else { return }
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        guard !refuseLockedEdit(layer: document.activeLayerIndex, kind: RZ_EDIT_PIXELS)
        else { return }
        let width = doc.width
        let height = doc.height
        // An outline is traced over a canvas of a given size; a document
        // resized under the gesture (an agent edit can land mid-press) leaves
        // it describing a picture that is gone.
        guard result.region.canvasWidth == width, result.region.canvasHeight == height else {
            NSSound.beep()
            return
        }
        let index = document.activeLayerIndex
        // Sample All Layers picks the SNAPSHOT and nothing else, exactly as
        // the Healing Brush does: on (the default), the flattened composite
        // the canvas is already showing; off, the active layer's own pixels
        // placed in canvas space and transparent elsewhere, so a patch that
        // reaches past the layer takes no coverage there. The core never
        // learns which was chosen. `patchSourceImage` is the ONE place that
        // choice is made — the canvas asks it too, when the region is placed,
        // so the pixels the drag showed are the pixels this commit takes.
        guard let snapshot = patchSourceImage()
            ?? (document.projection ?? doc.flattened())?.makeCGImage(in: doc.colorSpace)
        else {
            NSSound.beep()
            return
        }

        let count = width * height * 4
        let overlay = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        overlay.initialize(repeating: 0, count: count)
        defer {
            overlay.deinitialize(count: count)
            overlay.deallocate()
        }
        guard PatchSession.buildOverlay(
            result: result, snapshot: snapshot,
            // The same reading of the Direction option the drag's feedback
            // used a moment ago, so what was shown is what lands.
            destination: PatchSession.isDestination, space: doc.drawingSpace,
            width: width, height: height, into: overlay)
        else {
            // The patch cannot land at all: the drag rounded to nothing, or
            // it carried the sampled area off the picture.
            NSSound.beep()
            return
        }

        // §0.7(a): `healLayer` THROWS a documented memory limit that has to
        // reach the user, inside a transform closure that cannot. Latch the
        // message rather than `try?`-ing it away.
        var thrown: String?
        // The commit blocks the main thread, and it can block for a long
        // time: `heal_layer`'s only size bound is the 32-megapixel memory
        // limit on one region's box, so outlining most of a 5000 x 5000 scan
        // is an accepted call that measures 10.3 s of solve. Nothing on
        // screen can move while it runs, so say so with the cursor — the same
        // wrapper the Spot Healing Brush's commit uses, whose worst case is
        // the shorter of the two.
        Self.whileBusy {
            document.applyRasterizingEdit("Patch", layer: index) { current in
                do {
                    // strength 1: the Patch tool has no Opacity dial (neither
                    // does Photoshop's), and a partial heal here would be a
                    // half-moved patch rather than a softer one.
                    return try current.healLayer(
                        index, overlay: UnsafePointer(overlay), w: width, h: height, strength: 1)
                } catch let error as RasterCoreError {
                    thrown = error.message
                    return nil
                } catch {
                    thrown = error.localizedDescription
                    return nil
                }
            }
        }
        // The plain no-op — the region missed the layer's extent, or the two
        // areas already hold the same pixels — needs no signal of its own:
        // `applyEdit` beeps for any transform that answers nil (ImageDocument
        // :369), and beeping again for the same refusal was two system beeps
        // for one gesture. Only the MESSAGE path speaks, which is
        // `applyContentAwareFill`'s rule verbatim — it adds nothing to the
        // beep `applyEdit` already made.
        if let message = thrown { presentPatchFailure(message) }
    }

    /// Explains a refused patch instead of beeping at it: the core's refusals
    /// are limits with numbers in them and an instruction, and a beep throws
    /// that away. The drag is over by the time this runs, so a sheet is safe.
    private func presentPatchFailure(_ message: String) {
        let alert = NSAlert()
        // The core's messages are lowercase sentences meant to follow a
        // "… failed: " lead-in; an alert headline starts one.
        alert.messageText = message.prefix(1).uppercased() + message.dropFirst()
        alert.informativeText =
            "The patch was rolled back: the layer is unchanged and no undo step was added."
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
