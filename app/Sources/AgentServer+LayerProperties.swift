import AppKit

/// The per-entry property tools: set_layer_properties, reorder_layer, the
/// layer-mask family and set_layer_clipped.
///
/// They live here rather than in the frozen `AgentServer.swift` because layer
/// groups turned every one of them into structure work — each now looks its
/// target up with `structuralLayerIndex` (a GROUP is renamable, hideable,
/// maskable and clippable), asks `doc_lock` before it edits, and explains the
/// refusals a group or a lock produces instead of falling through to the
/// generic "check the parameters". The dispatch entries stay next door; the
/// handlers are here.
extension AgentServer {
    // MARK: - Order and properties

    func reorderLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let from = intArg(a, "from"), let to = intArg(a, "to") else {
            throw ToolError(message: "reorder_layer requires from and to")
        }
        // Validated here rather than left to the core's nil: an out-of-range
        // index used to come back as the generic "check the parameters"
        // while every other layer tool named the range.
        let count = document.doc?.layerCount ?? 0
        for (key, value) in [("from", from), ("to", to)] where value < 0 || value >= count {
            throw ToolError(
                message: "\(key) \(value) is out of range (0..\(count - 1))")
        }
        // Omitted depth means the destination row's own level, which is what
        // a drag onto a row means and what this tool has always done.
        let depth = intArg(a, "depth") ?? document.doc?.layerDepth(to) ?? 0
        guard
            try editStructure(document, "Reorder Layer", {
                $0.moveLayerTo(from: from, to: to, depth: depth)
            })
        else {
            throw ToolError(
                message: "Reorder Layer moved nothing. `to` numbers the stack with layer "
                    + "\(from)'s own subtree ALREADY taken out, so a `to` equal to that "
                    + "subtree's start at the same depth puts the layer back where it "
                    + "started — get_document reports each layer's depth and parent. Any "
                    + "other refusal means the (to, depth) pair would not leave a "
                    + "well-formed tree: a layer at depth d needs an enclosing group, and "
                    + "the topmost entry has to sit at depth 0.")
        }
        return try jsonResult(["ok": true, "document": summary(document)])
    }

    func setLayerProperties(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        // Every property here means the same thing on a GROUP as on a layer.
        let index = try structuralLayerIndex(a, document)
        // The ONE call site that accepts "Pass Through": it is a GROUP's
        // default mode, so a group whose blend mode was changed has to be
        // able to get back to it. brush_stroke and clone_stamp keep the
        // narrower vocabulary (AgentServer+Retouch.blendModeArg).
        let blendMode = try blendModeArg(a, allowPassThrough: true)
        let name = stringArg(a, "name")
        let opacity = doubleArg(a, "opacity")
        let visible = boolArg(a, "visible")
        let offsetX = intArg(a, "offset_x")
        let offsetY = intArg(a, "offset_y")
        let open = boolArg(a, "open")
        guard name != nil || opacity != nil || visible != nil || blendMode != nil
            || offsetX != nil || offsetY != nil || open != nil
        else {
            throw ToolError(message: "set_layer_properties: nothing to change")
        }
        if open != nil, document.doc?.layerIsGroup(index) != true {
            throw ToolError(
                message: "open applies to groups only — layer \(index) is a raster layer.")
        }
        // Named here rather than left to the core's NULL: without it the
        // refusal reads "Layer Properties failed — check the parameters",
        // which sends a model looking for the wrong problem.
        if blendMode == RZ_BLEND_PASS_THROUGH, document.doc?.layerIsGroup(index) != true {
            throw ToolError(
                message: "Pass Through applies to groups only — layer \(index) is a raster "
                    + "layer. It means \"do not composite this level as a unit\", which has "
                    + "no meaning outside a group; use Normal for a layer.")
        }
        // An offset is a MOVE, so it answers to the position lock — over the
        // SUBTREE, because writing a group's offset shifts every raster
        // descendant and the core's `lock_block` ORs their bits in
        // (AgentServer+Groups.rejectLockedOffset).
        if offsetX != nil || offsetY != nil {
            try rejectLockedOffset(document, index)
        }
        // A per-field no-op falls THROUGH instead of nilling the chain. Every
        // setter here answers NULL when the value it is handed is already the
        // stored one (the core's purity rule), so chaining them made ONE such
        // field discard every other property in the call — the read-modify-
        // write an agent performs after get_document, reported as "check the
        // parameters". `ImageDocument.applyToSelectedLayers` reads a nil the
        // same way, and a call in which nothing at all changed answers
        // `changed: false` below rather than an error.
        var changed = false
        guard
            try editStructure(document, "Layer Properties", { doc in
                var updated = doc
                func step(_ next: RasterDocument?) {
                    guard let next = next else { return }
                    updated = next
                    changed = true
                }
                if let name = name { step(updated.withLayerName(index, name)) }
                if let opacity = opacity {
                    step(updated.withLayerOpacity(index, min(max(opacity, 0), 1)))
                }
                if let mode = blendMode { step(updated.withLayerBlendMode(index, mode)) }
                if let visible = visible { step(updated.withLayerVisible(index, visible)) }
                if offsetX != nil || offsetY != nil {
                    let info = doc.layerInfo(index)
                    step(
                        updated.withLayerOffset(
                            index, offsetX ?? info?.offsetX ?? 0, offsetY ?? info?.offsetY ?? 0))
                }
                // A group's disclosure. Saved with the document, so it is a
                // real change — it simply changes no pixel.
                if let open = open { step(updated.withLayerOpen(index, open)) }
                return changed ? updated : nil
            })
        else {
            return try structureNoOp(
                ["layer": index],
                why: "layer \(index) already carries every property this call named.")
        }
        return try jsonResult(["ok": true, "document": summary(document)])
    }

    // MARK: - Layer masks

    /// The mask-owning layer a call targets, verified to actually have a
    /// mask so the failure names the fix instead of a generic edit error.
    /// Internal, not private: AgentServer+ChannelTargets routes a mask
    /// target through it.
    func maskedLayerIndex(
        _ a: [String: Any], _ document: ImageDocument, _ what: String
    ) throws -> Int {
        // A GROUP takes a mask too (a canvas-sized one), so this is the
        // structural lookup, not the pixel one.
        let index = try structuralLayerIndex(a, document)
        guard document.doc?.layerHasMask(index) == true else {
            throw ToolError(
                message: "Layer \(index) has no mask to \(what). Add one with add_layer_mask.")
        }
        return index
    }

    func addLayerMask(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        // A GROUP takes a mask (a canvas-sized one), so this is one of the
        // three tools here that must NOT take the paint helper's refusal.
        let index = try structuralLayerIndex(a, document)
        // A MASK edit, which only Lock All forbids (doc_lock.rs) — named here
        // so the refusal is not the generic "Add Layer Mask failed".
        try rejectLockedEdit(document, index, RZ_EDIT_MASK)
        let kindName = stringArg(a, "kind") ?? "reveal_all"
        let kind: RzMaskKind
        var selection: [UInt8]? = nil
        switch kindName {
        case "reveal_all": kind = RZ_MASK_REVEAL_ALL
        case "hide_all": kind = RZ_MASK_HIDE_ALL
        case "from_selection":
            // The window's live selection — the same one the marquee shows;
            // the core crops the canvas-sized coverage to the layer's rect.
            guard let mask = selectionMask(document) else {
                throw ToolError(
                    message: "kind \"from_selection\" needs an active selection, and there is "
                        + "none. Make one with a select_* tool first, or use kind "
                        + "\"reveal_all\" / \"hide_all\".")
            }
            kind = RZ_MASK_FROM_SELECTION
            selection = mask
        case let other:
            throw ToolError(
                message: "kind must be reveal_all, hide_all, or from_selection (got \"\(other)\")")
        }
        try performGroupedEdit(document, "Add Layer Mask") {
            $0.addingLayerMask(index, kind: kind, selection: selection)
        }
        return try jsonResult(["ok": true, "layer": index, "kind": kindName, "mask_enabled": true])
    }

    func removeLayerMask(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let apply = boolArg(a, "apply") ?? false
        let index = try maskedLayerIndex(a, document, apply ? "apply" : "remove")
        // A MASK edit under Lock All — including with apply, which does write
        // pixels: applying a mask is a mask operation (doc_lock.rs).
        // Applying a mask bakes its coverage into the layer's ALPHA, which is
        // its own edit kind: Lock Transparency refuses it, while deleting the
        // mask (which touches no alpha) stays a plain mask edit.
        try rejectLockedEdit(document, index, apply ? RZ_EDIT_MASK_APPLY : RZ_EDIT_MASK)
        // Applying bakes the coverage into the layer's own pixels, and a
        // group has none — the core answers NULL for it. Named here, like
        // every other group refusal: a permanent property of the target read
        // back as "check the parameters" sends a model round the same call
        // again with the same arguments.
        if apply, document.doc?.layerIsGroup(index) == true {
            throw ToolError(
                message: "Layer \(index) is a group: applying a mask bakes its coverage into "
                    + "a layer's pixels, and a group has none of its own. Delete the group's "
                    + "mask with apply: false, or apply the mask on the layers inside it.")
        }
        try performGroupedEdit(document, apply ? "Apply Layer Mask" : "Delete Layer Mask") {
            $0.removingLayerMask(index, apply: apply)
        }
        return try jsonResult(["ok": true, "layer": index, "applied": apply])
    }

    func setLayerMaskEnabled(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let enabled = boolArg(a, "enabled") else {
            throw ToolError(message: "set_layer_mask_enabled requires enabled (true or false)")
        }
        let index = try maskedLayerIndex(a, document, enabled ? "enable" : "disable")
        try rejectLockedEdit(document, index, RZ_EDIT_MASK)
        try performGroupedEdit(document, enabled ? "Enable Layer Mask" : "Disable Layer Mask") {
            $0.withLayerMaskEnabled(index, enabled)
        }
        return try jsonResult(["ok": true, "layer": index, "mask_enabled": enabled])
    }

    // MARK: - Clipping masks

    /// set_layer_clipped: the agent mirror of Layer > Create/Release
    /// Clipping Mask, named the same way so the undo menu reads identically.
    /// The core accepts a clipped BOTTOM layer (it composites as unclipped —
    /// there is nothing below to clip to), so that call succeeds with a
    /// note instead of erroring: the flag is real and matters the moment a
    /// layer is reordered beneath it.
    func setLayerClipped(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        // A group may be clipped, and may be a clip base.
        let index = try structuralLayerIndex(a, document)
        guard let clipped = boolArg(a, "clipped") else {
            throw ToolError(message: "set_layer_clipped requires clipped (true or false)")
        }
        try performGroupedEdit(document, clipped ? "Create Clipping Mask" : "Release Clipping Mask") {
            $0.withLayerClipped(index, clipped: clipped)
        }
        var result: [String: Any] = ["ok": true, "layer": index, "clipped": clipped]
        if clipped, let doc = document.doc, Self.isBaseless(doc, index) {
            result["note"] =
                "Layer \(index) is the bottom of its own level — clipping is re-derived "
                + "WITHIN a level, and there is no unclipped sibling beneath it there to "
                + "clip to — so it composites as if unclipped (a group of its own keeps "
                + "passing through). The flag is stored and takes effect the moment an "
                + "unclipped sibling sits below it."
        }
        return try jsonResult(result)
    }

    /// True when entry `index`'s clipped flag has nothing to act on: every
    /// sibling BELOW it in its own level is clipped too, so the compositor
    /// runs out of level before it finds a base and composites the entry as
    /// if unclipped (`doc_group::composite_level_into`). The bottom layer of
    /// a flat document is the familiar case; a group's bottom-most child is
    /// the one groups added, and an arrange or a panel drag reaches it
    /// without anyone touching the flag.
    private static func isBaseless(_ doc: RasterDocument, _ index: Int) -> Bool {
        doc.layerTree.siblings(of: index)
            .prefix { $0 != index }
            .allSatisfy { doc.layerClipped($0) }
    }
}
