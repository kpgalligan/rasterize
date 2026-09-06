import AppKit

/// The agent mirror of Edit > Content-Aware Fill…: the same core op the
/// sheet's Apply runs, over the same live selection the marquee shows, so
/// identical inputs give identical pixels.
extension AgentServer {

    /// content_aware_fill — mirrors Edit > Content-Aware Fill…
    /// (`EditorViewController.contentAwareFill`, whose sheet carries these
    /// same three parameters). The current selection is the region: it is
    /// inpainted from a ring of valid pixels around it and the result is
    /// Poisson-blended to the surrounding illumination, in ONE undo step.
    ///
    /// The selection's SOFT bytes weight the write-back, so a feathered
    /// selection blends and nothing outside it moves — which is why the mask
    /// crosses as coverage rather than as a rectangle.
    func contentAwareFill(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        // The UI disables the menu item on an adjustment layer
        // (validateUserInterfaceItem) and refuses again in
        // contentAwareFill(_:): there are no pixels to fill.
        try rejectAdjustmentPixelEdit(document, index)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard let mask = editor(document)?.agentSelection?.maskBytes(),
            mask.count == doc.width * doc.height
        else {
            throw ToolError(
                message: "There is no selection to fill. Make one first with select_rect, "
                    + "select_ellipse, select_polygon, select_magic_wand or select_subject "
                    + "— content_aware_fill fills the selection and nothing else.")
        }
        let ring = intArg(a, "ring") ?? 0
        guard ring >= 0, ring <= 512 else {
            throw ToolError(
                message: "ring must be between 0 and 512 (px); 0 is automatic, anything "
                    + "from 1 to 20 is raised to 21 (three patch widths), and a ring "
                    + "narrower than the region is widened from below in any case.")
        }
        let rawSeed = intArg(a, "seed") ?? 0
        guard rawSeed >= 0 else {
            throw ToolError(message: "seed must be a non-negative integer")
        }
        let seed = UInt64(rawSeed)
        let sampleAll = boolArg(a, "sample_all_layers") ?? false
        // What the fill will actually work on, and the one number the caps
        // are stated in — worth reporting whether the call succeeds or is
        // refused, because it is what the model has to make smaller. Every
        // pixel the selection TOUCHES counts, not just those over half
        // coverage: a fill takes its region out to the far edge of a
        // feathered ramp so the fade is continuous, and the core's own cap
        // counts the same set, so counting differently here would quote the
        // model a number its refusal contradicts.
        let selected = mask.reduce(into: 0) { count, coverage in
            if coverage > 0 { count += 1 }
        }

        let rasterized: DroppedDescription?
        // Two latches, in the §0.7(a) shape: `thrown` carries the core's own
        // refusal message (a cap, a starved neighbourhood) out of the
        // non-throwing transform, and `opRefused` marks the plain nil — so
        // neither ever reaches the model as performGroupedEdit's generic
        // "failed — check the parameters", which would be wrong for both.
        var thrown: String?
        var opRefused = false
        do {
            rasterized = try performPixelEdit(
                document, "Content-Aware Fill", pixelLayer: index
            ) { current in
                do {
                    let out = try current.contentAwareFilled(
                        index, mask: mask, ring: ring, seed: seed,
                        sampleAllLayers: sampleAll, preview: false)
                    if out == nil { opRefused = true }
                    return out
                } catch let error as RasterCoreError {
                    thrown = error.message
                    return nil
                } catch {
                    thrown = error.localizedDescription
                    return nil
                }
            }
        } catch let error as ToolError {
            if let message = thrown {
                // The core's sentence, capitalized into one: it names the
                // limit and what to do about it.
                throw ToolError(message: message.prefix(1).uppercased() + message.dropFirst())
            }
            guard opRefused else { throw error }
            // The commonest cause is FIRST, because the two after it are the
            // exotic ones: an exact fill of a region that already held the
            // right pixels is byte-identical, which is the documented and
            // tested behaviour of a flat or already-correct area, and a note
            // that lists only the layer-extent causes sends a model off to
            // debug a layer that is fine. `healNoOpResult` and `patchRegion`
            // both name it; this is the same sentence in the same family.
            throw ToolError(
                message: "Content-Aware Fill changed nothing: the selection touches "
                    + "\(selected) pixels on layer \(index) — the fill may "
                    + "have reproduced what was already there (a flat or already-correct "
                    + "region comes back byte-identical), or the selection may miss the "
                    + "layer's extent, or land only on transparent pixels, which have "
                    + "no illumination to blend to.")
        }
        return try pixelEditResult(
            [
                "ok": true, "action": "Content-Aware Fill", "layer": index,
                "selected_pixels": selected, "ring": ring, "seed": rawSeed,
                "sample_all_layers": sampleAll,
            ], layer: index, rasterized: rasterized)
    }
}
