import AppKit

/// Layer ▸ New Group / Ungroup Layers, the clipping-mask toggle, and the
/// Move tool's Auto-Select.
///
/// The three belong together because all three are questions about the
/// TREE: what a layer is inside, what it clips to, and which entry a click
/// lands on. The core re-derives that tree positionally on every composite
/// (`doc_group`), the host re-derives it on every panel reload
/// (`LayerTree`), and nothing here keeps a second copy of it.
///
/// Every action is ONE core call inside ONE `applyEdit`. That is not a style
/// preference: every structural op renumbers the stack, so a host loop over
/// several indices would address the wrong entries from its second iteration
/// on, which is why the core exports `rz_doc_*_layers` at all.
extension EditorViewController {
    // MARK: - Group and ungroup

    /// ⌘G. Wraps the selection in a new group and selects it.
    ///
    /// The core reports two things the user has to be told about, because
    /// both change the picture and neither is visible in the layer list:
    /// the bottom-most grouped entry loses its CLIPPED flag when its base
    /// stayed outside the group (nothing inside is below it to clip to), and
    /// a NON-CONTIGUOUS selection gathers its subtrees into the topmost
    /// slot, so entries left between them change their relative order.
    ///
    /// The group is created INSIDE `applyEdit`'s closure rather than before
    /// it, so the entries are resolved against exactly the handle the edit
    /// commits — the one rule that keeps an index from naming a different
    /// layer than the one it was measured on.
    @objc func groupLayers(_ sender: Any?) {
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        let indices = document.selectedLayerIndices
        // The same default `group_layers` uses, and the same shape
        // `newLayer` names a layer with: a count of what the panel shows at
        // the top level, so the number reads as "the next one".
        let name = "Group \(doc.layerTree.topLevel().count + 1)"
        var report: (group: Int, cleared: [Int], reordered: [Int])?
        document.applyEdit("Group Layers") { doc in
            guard let result = doc.groupLayers(indices, name: name) else { return nil }
            report = (result.group, result.clearedClip, result.reordered)
            return result.document
        }
        // nil means the core refused (a selection spanning two parents, an
        // entry with its own child, or the depth cap) and `applyEdit` has
        // already beeped.
        guard let report = report else { return }
        setActiveLayer(report.group)
        reportGroupChanges(cleared: report.cleared, reordered: report.reordered)
    }

    /// Says what `groupLayers` changed beyond the nesting, in the same brief
    /// app-modal shape `refuseAdjustmentPixelEdit` uses. Silent when there
    /// is nothing to say, which is the common case — a contiguous selection
    /// with no clipping in it produces both lists empty.
    ///
    /// The cleared entries are NAMED (they are the core's post-edit indices,
    /// so they can be looked up in the document the edit just committed);
    /// the reordered ones are only counted, because a non-contiguous group
    /// can shift a dozen entries and a dozen names is not a brief note.
    private func reportGroupChanges(cleared: [Int], reordered: [Int]) {
        guard !cleared.isEmpty || !reordered.isEmpty else { return }
        var lines: [String] = []
        if !cleared.isEmpty {
            let names = cleared.compactMap { document?.doc?.layerInfo($0)?.name }
                .map { "“\($0)”" }
            let subject = names.isEmpty
                ? "The clipping mask on the bottom layer of the group"
                : "The clipping mask on \(Self.list(names))"
            lines.append(
                "\(subject) was released: the layer it clipped to stayed outside the group, "
                + "and a clipped layer at the bottom of its group has nothing to clip to.")
        }
        if !reordered.isEmpty {
            lines.append(
                "The grouped layers were not next to each other, so they were gathered "
                + "together — \(Self.layerPhrase(reordered.count)) that sat between them "
                + "changed position.")
        }
        let alert = NSAlert()
        // Informational, not a warning: the edit succeeded and this is the
        // part of it the layer list cannot show.
        alert.alertStyle = .informational
        alert.messageText = "Grouped."
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.runModal()
    }

    /// ⇧⌘G. Dissolves the group under the primary entry; its children take
    /// its place and become the selection.
    ///
    /// Deliberately ONE group, the primary, even when several are selected:
    /// the core's op is per group and every ungroup renumbers, so a loop
    /// would dissolve whatever moved into the next index. Ungrouping several
    /// groups is two ⇧⌘G presses, which is also Photoshop's answer.
    ///
    /// A group's own mask, style, opacity, blend mode and clipped flag
    /// cannot be expressed on its children, so ungrouping DISCARDS them.
    /// That is a real loss of picture, so it is read off the group BEFORE
    /// the edit — afterwards the group is gone and nothing could name what
    /// it lost — and reported once the children are in place.
    @objc func ungroupLayers(_ sender: Any?) {
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        guard doc.layerIsGroup(idx), let info = doc.layerInfo(idx) else {
            NSSound.beep()
            return
        }
        // The group sits ABOVE its own children (it is the last record of
        // its subtree), so removing it leaves every child's index untouched
        // — which is what makes this list still valid after the edit.
        let children = doc.layerTree.children(of: idx)
        let discarded = discardedGroupProperties(doc, group: idx, info: info)
        let before = document.doc
        // The core's own report, read out of the edit: the bottom-most child
        // was baseless inside the group and would have gained a clip base at
        // the parent level, so its clipping mask was released instead.
        var clearedClip: [Int] = []
        document.applyEdit("Ungroup Layers") { doc in
            guard let result = doc.ungroupLayer(idx) else { return nil }
            clearedClip = result.clearedClip
            return result.document
        }
        guard document.doc !== before else { return }
        if let primary = children.last {
            setSelectedLayers(LayerSelection(primary: primary, others: Set(children)))
        }
        let released = clearedClip.map {
            document.doc?.layerInfo($0)?.name ?? "the bottom layer"
        }
        reportUngroupLoss(group: info.name, discarded: discarded, releasedClip: released)
    }

    /// What ungrouping `group` is about to throw away, in the words the
    /// alert reads out. Empty for a plain Pass Through group at full
    /// opacity, which is the common case and says nothing.
    ///
    /// Opacity is compared against 0.999 rather than 1 because it round
    /// trips through an `f32` percentage in the core; 100 % can come back as
    /// 0.99999994, and reporting a discarded opacity that was never set
    /// would be a lie in the other direction.
    private func discardedGroupProperties(
        _ doc: RasterDocument, group idx: Int, info: RasterDocument.LayerInfo
    ) -> [String] {
        var discarded: [String] = []
        if doc.layerHasMask(idx) { discarded.append("its mask") }
        if doc.layerHasStyle(idx) { discarded.append("its layer style") }
        if info.opacity < 0.999 {
            discarded.append("its opacity (\(Int((info.opacity * 100).rounded())) %)")
        }
        // Pass Through is a group's default and the one mode that means
        // "no isolation", so it is the only mode there is nothing to lose.
        if info.blendMode != RZ_BLEND_PASS_THROUGH {
            discarded.append("its blend mode (\(RzBlendMode.displayName(for: info.blendMode)))")
        }
        if doc.layerClipped(idx) { discarded.append("its clipping mask") }
        return discarded
    }

    /// The ungroup half of the same report: what the group's own properties
    /// cost, plus any clipping mask the core RELEASED to keep the picture.
    ///
    /// The second half is the mirror of `groupLayers`' `cleared_clip` alert
    /// and exists for the same reason: the bottom-most child was clipped to
    /// nothing inside the group, and out at the parent level it would have
    /// clipped to whatever sits below the group — a silent change of picture
    /// if it were neither prevented nor announced.
    private func reportUngroupLoss(
        group name: String, discarded: [String], releasedClip: [String]
    ) {
        guard !discarded.isEmpty || !releasedClip.isEmpty else { return }
        var lines: [String] = []
        if !discarded.isEmpty {
            lines.append("A group's children cannot carry " + Self.list(discarded) + ".")
        }
        for layer in releasedClip {
            lines.append(
                "“\(layer)” was clipped to nothing inside the group, so its clipping mask "
                    + "was released rather than re-pointed at the layer below the group.")
        }
        lines.append("Undo restores the group.")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText =
            discarded.isEmpty
            ? "Ungrouping “\(name)” released a clipping mask."
            : "Ungrouping “\(name)” discarded "
                + "\(discarded.count == 1 ? "one of" : "some of") its properties."
        alert.informativeText = lines.joined(separator: " ")
        alert.runModal()
    }

    /// "1 other layer" / "3 other layers" — pluralized rather than left as
    /// "layer(s)", which reads as an unfinished string.
    private static func layerPhrase(_ count: Int) -> String {
        count == 1 ? "1 other layer" : "\(count) other layers"
    }

    /// "a, b and c" — an English list, so the alert does not end in a
    /// trailing comma when a group loses three things at once.
    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Grouping needs every selected entry to sit in the SAME group, which
    /// is the core's rule; the menu says so first rather than letting ⌘G
    /// beep.
    ///
    /// That one test covers more than it looks: siblings' subtrees are
    /// disjoint, so a selection sharing one parent can never contain an
    /// entry together with its own descendant — the other case the core
    /// refuses. The DEPTH CAP is not checked here: the ceiling lives in the
    /// core (`MAX_GROUP_DEPTH`) and is not part of the FFI surface, so the
    /// item stays enabled at ten levels deep and the refusal is a beep.
    var canGroupLayers: Bool {
        guard let document = document, let doc = document.doc else { return false }
        let indices = document.selectedLayerIndices
        guard !indices.isEmpty else { return false }
        let tree = doc.layerTree
        // -1 stands for "no parent" (the top level), which is a real,
        // shared parent for this test.
        return Set(indices.map { tree.parent(of: $0) ?? -1 }).count == 1
    }

    var canUngroupLayers: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return doc.layerIsGroup(document.activeLayerIndex)
    }

    /// Merge Layers over a MULTI-selection — the same two pre-checks the core
    /// makes before it builds anything, so the menu item disables instead of
    /// beeping with no message.
    ///
    /// `merge_layers` requires ONE shared parent (merging across levels has no
    /// defined slot for the result — the same rule `canGroupLayers` tests) and
    /// refuses a HIDDEN lowest member, because the merge would replace it with
    /// a picture that discards the upper members' content. The single-selection
    /// branch of the same menu item already checks the second; without this the
    /// two halves of one item disagreed about whether to pre-check at all.
    var canMergeSelectedLayers: Bool {
        guard let document = document, let doc = document.doc else { return false }
        let indices = document.selectedLayerIndices
        guard indices.count > 1 else { return false }
        let tree = doc.layerTree
        // -1 stands for "no parent" (the top level), exactly as in
        // `canGroupLayers`.
        guard Set(indices.map { tree.parent(of: $0) ?? -1 }).count == 1 else { return false }
        return doc.layerInfo(indices[0])?.visible == true
    }

    // MARK: - Clipping masks (Layer ▸ Create/Release Clipping Mask)
    //
    // They live here because a clip run is re-derived WITHIN a level: what a
    // layer clips to is a question about the tree, and this file owns the
    // answer.

    /// Whether the ACTIVE layer is clipped to the entry below (drives the
    /// menu item's Create/Release retitle).
    var activeLayerClipped: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return doc.layerClipped(document.activeLayerIndex)
    }

    /// One toggling action, Photoshop-style: clips the selection to the
    /// entry below, or releases it. An entry that is first in its LEVEL has
    /// nothing below to clip to (validation disables the item; the core
    /// would composite it as unclipped anyway). Clip runs are positional in
    /// the core and re-derived WITHIN a level, so this flag flip is the
    /// whole edit — one undo step.
    ///
    /// Clipping a layer over a PASS-THROUGH GROUP makes that group composite
    /// as a unit, so an adjustment layer inside it stops reaching the layers
    /// below the group. That is the core's isolation rule (a clip base needs
    /// its own alpha footprint), it is published in the `set_layer_clipped`
    /// and `add_adjustment_layer` catalog entries, and it is why the note
    /// below is shown rather than left to be discovered.
    @objc func toggleClippingMask(_ sender: Any?) {
        guard let document = document, let doc = document.doc,
              let below = clippingBaseBelowActiveLayer
        else {
            NSSound.beep()
            return
        }
        let clipped = !doc.layerClipped(document.activeLayerIndex)
        document.applyToSelectedLayers(
            clipped ? "Create Clipping Mask" : "Release Clipping Mask"
        ) { $0.withLayerClipped($1, clipped: clipped) }
        if clipped { noteClippingOverPassThroughGroup(below) }
        updateStatus()
    }

    /// The entry the active layer would clip TO — the first entry below it
    /// among its SIBLINGS — or nil when it is first in its level. One
    /// derivation, read by the action, by its menu validation and by Merge
    /// Down's.
    var clippingBaseBelowActiveLayer: Int? {
        guard let document = document, let doc = document.doc else { return nil }
        let idx = document.activeLayerIndex
        return doc.layerTree.siblings(of: idx).last { $0 < idx }
    }

    /// Says, once, what clipping a layer over a PASS-THROUGH group does to
    /// the adjustment layers inside it: the group has to composite as a unit
    /// to have an alpha footprint for the clip, and an adjustment inside an
    /// isolated group can no longer reach the layers below the group.
    ///
    /// It is the core's own isolation rule and it is published rather than
    /// left to be discovered — here, in the `set_layer_clipped` and
    /// `add_adjustment_layer` catalog entries, and in `doc_group`'s module
    /// doc. Silent unless the group below really does hold an adjustment
    /// layer, which is the only configuration where the rule changes the
    /// picture.
    func noteClippingOverPassThroughGroup(_ below: Int) {
        guard let doc = document?.doc, doc.layerIsGroup(below),
              doc.layerInfo(below)?.blendMode == RZ_BLEND_PASS_THROUGH,
              doc.layerTree.subtree(of: below).contains(where: { doc.layerIsAdjustment($0) })
        else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "The group below now composites as a unit."
        alert.informativeText =
            "Clipping a layer to a Pass Through group makes that group render on its own, "
            + "so the adjustment layer inside it no longer reaches the layers beneath the "
            + "group. Release the clipping mask to get it back."
        alert.runModal()
    }

    // MARK: - A group has no pixels

    /// Refuses a pixel edit aimed at a GROUP, with a brief app-modal alert
    /// saying why; true when refused.
    ///
    /// The twin of `refuseAdjustmentPixelEdit()` and
    /// `refuseLockedEdit(layer:kind:)`, and for the same reason: a group is
    /// the active layer the instant ⌘G runs (`groupLayers` selects it), and
    /// the canvas paths — a brush stroke, a bucket fill, a gradient drag, a
    /// filter — are outside menu validation's reach. Without it a stroke on
    /// a group opened a live edit, painted nothing on every tick and ended
    /// with no undo step, no beep and no message: the one failure shape the
    /// agent side already refuses in words ("Layer N is a group: it has no
    /// pixels of its own to edit").
    @discardableResult
    func refuseGroupPixelEdit() -> Bool {
        guard let document = document, let doc = document.doc, activeLayerIsGroup else {
            return false
        }
        let name = doc.layerInfo(document.activeLayerIndex)?.name ?? "This group"
        let alert = NSAlert()
        alert.messageText = "“\(name)” is a group, and a group has no pixels of its own."
        alert.informativeText = "Select a layer inside it to edit."
        alert.runModal()
        return true
    }

    /// Whether the ACTIVE entry is a GROUP — menu validation's twin of the
    /// alert above, so a pixel item DIMS instead of offering an edit that can
    /// only be refused (the `activeLayerIsAdjustment` shape).
    var activeLayerIsGroup: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return doc.layerIsGroup(document.activeLayerIndex)
    }

    // MARK: - Delete Layer's validation

    /// Whether Delete Layer would leave the document with anything in it.
    ///
    /// The core refuses only a removal that would empty the stack, so the
    /// test is on what would be LEFT — and what a removal TAKES is not the
    /// number of selected rows: deleting a group takes its whole subtree,
    /// and a selection holding a group and one of its own children takes
    /// that subtree once (`LayerTree.removalCount`, mirroring the core's
    /// `independent_roots`). Counting rows left the command enabled on a
    /// document whose only top-level entry is a group, where it can do
    /// nothing but beep.
    var canDeleteLayer: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return doc.removalLeavesLayers(document.selectedLayerIndices)
    }

    // MARK: - Move tool Auto-Select

    /// A Move press with Auto-Select on activates the topmost entry whose
    /// own coverage under the cursor is at least half — or that entry's
    /// top-level GROUP, when the options bar's popup says Group.
    ///
    /// A MISS leaves the selection alone rather than emptying it: a document
    /// always has an active layer, and clicking empty canvas is not a
    /// statement that nothing should be selected. ⇧-click ADDS the hit entry
    /// to the selection and makes it the primary, which is how a set is
    /// built on the canvas without going to the panel.
    ///
    /// It routes through `setActiveLayer` / `setSelectedLayers`, whose
    /// whole-selection early-out is what keeps a click on the already-active
    /// layer from rebuilding every row thumbnail in the panel — this runs on
    /// every move-begin, so that guard is load-bearing for cost and not only
    /// for correctness.
    func autoSelectLayer(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard ToolOptionsStore.shared.move.autoSelect,
              let document = document, let doc = document.doc,
              // The popup's second entry is Group; the core answers with the
              // hit entry's top-level ancestor rather than the host walking
              // the tree, so both sides agree on what "the group" is.
              let hit = doc.layerAt(
                point, topLevel: ToolOptionsStore.shared.move.autoSelectIndex == 1)
        else { return }
        if modifiers.contains(.shift) {
            setSelectedLayers(document.layerSelection.adding(hit))
        } else {
            setActiveLayer(hit)
        }
    }
}
