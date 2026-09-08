import AppKit

/// Layer ▸ Layer Via Copy / Via Cut, Merge Visible and Stamp Visible — the
/// four workflow commands that make a new layer out of what is already
/// there.
///
/// ## Why ⌘J is ROUTED rather than being one core call
///
/// Photoshop's ⌘J is Layer Via Copy, and this build now puts it there. But
/// the core's `layer_via` RASTERIZES: it keeps neither the layer's
/// re-openable description nor its style, and it refuses a group and an
/// adjustment layer outright. Sending every ⌘J through it would silently
/// turn a text, shape or Live Photo layer into pixels — breaking the
/// described-layer invariant that every destructive path ASKS first — beep
/// on a group or an adjustment layer, and quietly drop a style.
///
/// `duplicatingLayer` already does the right thing in all of those cases: it
/// clones the whole entry, meta, style and subtree included. So the ACTION
/// branches, and `layerVia` is reached only where it is the better answer:
///
/// - no canvas selection, or the target is a GROUP, an ADJUSTMENT layer or a
///   DESCRIBED layer → `duplicateLayer` (full fidelity);
/// - SEVERAL entries selected → `duplicateLayer` too. `layer_via` is a
///   single-entry op, and taking the primary alone would silently drop the
///   rest of the selection, which is the one thing a set-aware build must
///   not do. Duplicating them all is what "copy these" meant.
/// - a plain raster layer, alone, with a live selection → `layerVia`.
///
/// The `layer_via_copy` MCP tool deliberately does NOT route: an agent
/// calling it asks for the rasterizing op by name, and its catalog entry
/// says so. The routing is the ⌘J *gesture*'s promise, not the op's.
///
/// Layer Via CUT has no such escape — cutting pixels out of a described
/// layer really does contradict its description — so it takes the ordinary
/// `applyRasterizingEdit` prompt, and it is disabled for a multi-selection
/// because cutting several layers into one new layer has no meaning.
extension EditorViewController {
    // MARK: - Layer Via Copy / Via Cut

    /// ⌘J. See the routing rule in this file's doc comment.
    @objc func layerViaCopy(_ sender: Any?) {
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        guard !document.layerSelection.isMultiple,
              !doc.layerIsGroup(idx), !doc.layerIsAdjustment(idx),
              !document.layerDescribesSource(idx),
              let mask = canvas.selection?.maskBytes()
        else {
            duplicateLayer(sender)
            return
        }
        let name = viaLayerName(doc, layer: idx)
        // Where the copy lands, from the stack BEFORE the edit: the core's
        // own answer, because `idx + 1` is the wrong index the moment the
        // entry below the insertion point is a group.
        let landing = doc.insertionIndex(above: idx)
        let before = document.doc
        // The SOURCE is untouched by a copy, so no rasterize prompt and no
        // pixel-lock check: nothing is written to it.
        document.applyEdit("Layer Via Copy") {
            $0.layerVia(idx, mask: mask, cut: false, name: name)
        }
        guard document.doc !== before else { return }
        setActiveLayer(min(landing, document.doc.layerCount - 1))
    }

    /// ⇧⌘J. Lifts the selected pixels out of the layer into a new one above
    /// it — the copy half plus a clear of the same coverage, which the core
    /// does as ONE op so the two halves can never disagree about which
    /// pixels moved.
    @objc func layerViaCut(_ sender: Any?) {
        guard let document = document, let doc = document.doc,
              !document.layerSelection.isMultiple,
              let mask = canvas.selection?.maskBytes()
        else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        guard !doc.layerIsGroup(idx), !doc.layerIsAdjustment(idx) else {
            NSSound.beep()
            return
        }
        // The lock is asked about BEFORE the rasterize prompt: refusing an
        // edit after the user has already agreed to lose a text layer's
        // description would be the wrong order to ask two questions in.
        guard !refuseLockedEdit(layer: idx, kind: RZ_EDIT_PIXELS) else { return }
        let name = viaLayerName(doc, layer: idx)
        let landing = doc.insertionIndex(above: idx)
        let before = document.doc
        // The cut half rewrites the SOURCE layer's pixels, so a described
        // layer is asked about — and its description dropped inside the same
        // undo step — exactly as a paint stroke would. That is what
        // `applyRasterizingEdit` is, so it is used rather than repeated.
        document.applyRasterizingEdit("Layer Via Cut", layer: idx) {
            $0.layerVia(idx, mask: mask, cut: true, name: name)
        }
        guard document.doc !== before else {
            // The cut half only REMOVES coverage, so a frozen alpha channel
            // makes the whole op a byte-exact no-op — a refusal the Pixels
            // check above cannot see (the transparency bit is not one of the
            // bits it reports), and one that would otherwise be a bare beep.
            refuseFrozenAlpha(layer: idx)
            return
        }
        setActiveLayer(min(landing, document.doc.layerCount - 1))
    }

    /// The same default name the `layer_via_copy` / `layer_via_cut` tools
    /// use, so a document edited from both sides reads consistently.
    private func viaLayerName(_ doc: RasterDocument, layer idx: Int) -> String {
        (doc.layerInfo(idx)?.name ?? "Layer") + " copy"
    }

    /// ⌘J is available on any document: with no selection — or on a group,
    /// an adjustment layer, a described layer or a multi-selection — it
    /// duplicates instead, which is exactly the routing above.
    var canLayerViaCopy: Bool { document?.doc != nil }

    /// ⇧⌘J needs one raster entry and something to cut out of it. A group
    /// and an adjustment layer have no pixels of their own; a multi-selection
    /// has no single source.
    var canLayerViaCut: Bool {
        guard let document = document, let doc = document.doc,
              !document.layerSelection.isMultiple, canvas.selection != nil
        else { return false }
        let idx = document.activeLayerIndex
        return !doc.layerIsGroup(idx) && !doc.layerIsAdjustment(idx)
    }

    // MARK: - Merge Visible / Stamp Visible

    /// Replaces every entry that CONTRIBUTES to the projection with one
    /// layer holding it.
    ///
    /// "Contributes" means visible AND every enclosing group visible, and
    /// the core uses that one predicate for both halves of the op — which
    /// entries are merged and which survive. So a visible layer inside a
    /// HIDDEN group contributes nothing and is never merged away: it comes
    /// out the other side untouched.
    @objc func mergeVisible(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        let before = document.doc
        // Where the merged layer lands, from the stack BEFORE the merge: the
        // slot of the bottom-most contributing entry's top-level ancestor,
        // counted against the entries that survive below it. nil is exactly
        // the case the core refuses (fewer than two contributing leaves).
        let landing = before?.mergeVisibleLanding()
        document.applyEdit("Merge Visible") { $0.mergeVisible() }
        guard document.doc !== before, let landing = landing else { return }
        setActiveLayer(min(landing, document.doc.layerCount - 1))
    }

    /// ⇧⌥⌘E. Adds the visible projection as a NEW layer above the active
    /// entry's subtree and leaves the rest of the stack exactly as it was —
    /// Merge Visible's non-destructive twin.
    @objc func stampVisible(_ sender: Any?) {
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        let landing = doc.insertionIndex(above: idx)
        let before = document.doc
        // The same default name the `stamp_visible` tool uses.
        document.applyEdit("Stamp Visible") { $0.stampVisible(above: idx, name: "Stamp") }
        guard document.doc !== before else { return }
        setActiveLayer(min(landing, document.doc.layerCount - 1))
    }

    /// Merging the visible entries needs at least two LEAF entries that
    /// actually contribute — counting entries would count group rows, and a
    /// single layer inside one visible group would wrongly satisfy the
    /// floor. Same predicate as the core's, written once in `LayerTree` so
    /// the menu and the edit can never disagree.
    var canMergeVisible: Bool {
        (document?.doc?.contributingLeaves().count ?? 0) >= 2
    }

    /// Stamping needs only something visible to stamp; the core refuses an
    /// entirely hidden stack and the action beeps.
    var canStampVisible: Bool { document?.doc != nil }
}
