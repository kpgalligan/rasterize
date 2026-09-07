import AppKit

/// The layers panel's ROW behaviour: selection, the thumbnail click, the
/// drag reorder, the disclosure and the row menu — everything that reads
/// `rows`, `tree` and `tableView` rather than building them.
///
/// Split out of `LayersPanelViewController` because the panel gained a tree,
/// a multi-selection and a drag that can now change an entry's LEVEL, which
/// is a MARK block's worth of behaviour on its own (`app/CLAUDE.md`: a
/// feature's MARK block is exactly the granularity that becomes a file).
///
/// Two facts shape everything below. Rows are TOP-FIRST while the stack is
/// bottom-first, so "above row R" in the table means "immediately above entry
/// R in the stack" — the far end of R's own SUBTREE, which is `R + 1` only
/// when R is a plain layer. And a row is an ADDRESS that every structural
/// edit renumbers, so an index is re-derived after each move rather than
/// carried across one.
extension LayersPanelViewController {
    // MARK: - Selection

    /// The table's selection became the document's.
    ///
    /// The early-out compares the WHOLE selection, not just the primary: it
    /// is load-bearing for cost, because `onActiveLayerChange` ends in
    /// `activeLayerDidChange()`, which reloads the panel — and a reload that
    /// answers "nothing changed" is pure waste on every canvas click that
    /// auto-select routes through here.
    ///
    /// The selection this writes is what the ROWS show. A layer selected
    /// inside a group that is then closed keeps its membership and is drawn
    /// on the group's row (`reload()` maps it there), so the next selection
    /// gesture replaces it with the group — the entry the user can actually
    /// see and clicked on.
    @objc func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let document = document, document.doc != nil else { return }
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let indices = selectedRows.compactMap { layerIndex(forRow: $0) }
        guard !indices.isEmpty else { return }
        // The row AppKit last touched is the primary — the layer the header
        // controls and every single-layer tool describe.
        let primary = layerIndex(forRow: tableView.selectedRow) ?? indices[0]
        let selection = LayerSelection(primary: primary, others: Set(indices))
        guard selection != document.layerSelection else { return }
        // Panel selection only retargets future edits: no undo, no dirty.
        document.setLayerSelection(selection)
        updateHeaderControls()
        updateButtonStates()
        onActiveLayerChange?()
        // The paint-target ring follows the active layer (and the editor has
        // just dropped any mask target the old layer had).
        refreshTargetRings()
    }

    /// A click on one of a row's thumbnails: make that layer the whole
    /// selection — a thumbnail click is a statement about ONE layer — then
    /// point brush/eraser at the clicked target.
    func selectPaintTarget(_ target: PaintTarget, layer idx: Int) {
        guard let document = document, document.doc != nil else { return }
        if document.layerSelection != .single(idx) {
            document.selectLayer(idx)
            if let row = row(forLayerIndex: idx), row < tableView.numberOfRows {
                isReloading = true
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isReloading = false
            }
            updateHeaderControls()
            updateButtonStates()
            // Resets the editor's paint target for the new layer; the
            // requested target lands right after.
            onActiveLayerChange?()
        }
        onPaintTargetChange?(target)
        refreshTargetRings()
    }

    // MARK: - Drag reorder

    /// One pasteboard item per dragged row: AppKit drags the WHOLE selection
    /// when the drag starts on a selected row, and every one of those rows
    /// has to reach `acceptDrop`.
    @objc func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> NSPasteboardWriting?
    {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: LayersPanelViewController.layerRowType)
        return item
    }

    /// `.above` any row — the table's own between-rows feedback — and `.on` a
    /// GROUP row, which drops INTO the group. Every other `.on` is retargeted
    /// to an insertion above that row, which is what the panel did before
    /// groups existed.
    @objc func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard
            info.draggingPasteboard.availableType(
                from: [LayersPanelViewController.layerRowType]) != nil
        else { return [] }
        let sources = draggedEntries(info)
        guard !sources.isEmpty else { return [] }
        var operation = dropOperation
        if operation == .on, dropTarget(row: row, operation: .on, moving: sources) == nil {
            // Not a group, or a group that is itself being dragged (nothing
            // can become its own child): fall back to an insertion above the
            // row, the panel's pre-group behaviour.
            tableView.setDropRow(row, dropOperation: .above)
            operation = .above
        }
        guard dropTarget(row: row, operation: operation, moving: sources) != nil else { return [] }
        return .move
    }

    /// Drops the dragged entries where the drop line was drawn, keeping their
    /// relative order and their subtrees.
    ///
    /// ONE `applyEdit` — one gesture is one undo step — chaining one
    /// `moveLayerTo` per dragged entry, bottom-most first, each landing
    /// immediately above the one before it. The whole chain is computed
    /// BEFORE the edit is applied, so a drag that puts everything back
    /// exactly where it was answers false silently instead of leaving an undo
    /// step for a document that did not change.
    @objc func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let document = document, let doc = document.doc else { return false }
        let previousPrimary = document.layerSelection.primary
        let sources = draggedEntries(info)
        guard !sources.isEmpty,
              let drop = dropTarget(row: row, operation: dropOperation, moving: sources),
              let outcome = dragReorder(doc, sources: sources, drop: drop)
        else { return false }
        // A drag taken back: every entry landed on the index it started from,
        // at the depth it already had, so the document is the one we started
        // with.
        let sameDepth = sources.allSatisfy { tree.depth(of: $0) == drop.depth }
        guard outcome.landed != sources || !sameDepth else { return false }
        // The reorder was computed from this very handle a moment ago (so the
        // no-op above could be detected before an undo step existed), which
        // is why the closure has nothing left to do with its argument.
        document.applyEdit("Reorder Layer") { _ in outcome.document }
        // Keep the moved entries selected at their NEW indices — a subtree
        // that moved renumbered everything it passed — with the primary still
        // the entry it was whenever that entry was one of the dragged ones.
        let primary =
            sources.firstIndex(of: previousPrimary).map { outcome.landed[$0] }
            ?? outcome.landed.last
        if let primary = primary {
            document.setLayerSelection(
                LayerSelection(primary: primary, others: Set(outcome.landed)))
        }
        // A drop INTO a closed group would otherwise look like the layers
        // vanished, so the group opens to show them. Not part of the undo
        // step (disclosure never is) and a no-op when it was open already.
        if let into = outcome.into {
            document.setGroupExpanded(into, true)
        }
        reload()
        onActiveLayerChange?()
        return true
    }

    /// The entries a drag carries: every dragged row's entry, minus any entry
    /// that already travels inside another dragged GROUP (moving it a second
    /// time would pull it straight back out), ascending — which is the order
    /// the moves are issued in, and what keeps the set's relative stacking at
    /// the destination.
    private func draggedEntries(_ info: NSDraggingInfo) -> [Int] {
        let items = info.draggingPasteboard.pasteboardItems ?? []
        let indices = items.compactMap { item -> Int? in
            guard
                let text = item.string(forType: LayersPanelViewController.layerRowType),
                let row = Int(text)
            else { return nil }
            return layerIndex(forRow: row)
        }
        let dragged = Set(indices)
        return dragged.filter { idx in
            !tree.ancestors(of: idx).contains(where: dragged.contains)
        }.sorted()
    }

    /// Where a drop lands: the insertion index in the CURRENT stack that the
    /// dropped block's bottom record takes, the depth the dropped entries
    /// take there, and — for a drop INTO a group — that group, which the
    /// panel opens afterwards so the layers do not appear to vanish into a
    /// closed row. nil for a drop the model cannot express, which is what
    /// makes the drag feedback honest instead of beeping at the end.
    ///
    /// * `.on` a GROUP row drops INTO it, at the top of its children — which
    ///   is the group's own slot, since its children are the run immediately
    ///   below it. Refused for a non-group and for a group that is itself
    ///   being dragged.
    /// * `.above` a row inserts immediately above that entry's whole subtree,
    ///   at that entry's depth: a drop inside an open group stays in the
    ///   group, a drop above a top-level row leaves it.
    /// * Past the last row, the drop goes under the bottom-most visible
    ///   entry at that entry's depth — so a drop under the last child of an
    ///   open group lands inside the group, which is where the line was
    ///   drawn.
    /// * An insertion strictly INSIDE one of the dragged subtrees is refused:
    ///   an entry cannot land inside itself.
    ///
    /// Only EXPRESSIBILITY is decided here. The model's own limits — the
    /// nesting cap above all — stay the core's answer: `moveLayerTo` refuses,
    /// `acceptDrop` changes nothing and the drag simply does not take, which
    /// is the honest outcome for a drop the document cannot hold.
    private func dropTarget(
        row: Int, operation: NSTableView.DropOperation, moving sources: [Int]
    ) -> (at: Int, depth: Int, into: Int?)? {
        if operation == .on {
            guard row >= 0, row < rows.count else { return nil }
            let target = rows[row].index
            guard tree.isGroup(target), !sources.contains(where: { tree.contains($0, target) })
            else { return nil }
            return (target, tree.depth(of: target) + 1, target)
        }
        guard row >= 0 else { return nil }
        let landing: (at: Int, depth: Int, into: Int?)
        if row < rows.count {
            let target = rows[row].index
            landing = (tree.subtree(of: target).upperBound, tree.depth(of: target), nil)
        } else {
            guard let bottom = rows.last?.index else { return nil }
            landing = (tree.subtree(of: bottom).lowerBound, tree.depth(of: bottom), nil)
        }
        let inside = sources.contains { idx in
            let range = tree.subtree(of: idx)
            return landing.at > range.lowerBound && landing.at < range.upperBound
        }
        return inside ? nil : landing
    }

    /// The whole drag as ONE new document, plus where each dragged entry
    /// landed (parallel to `sources`) and where the group it was dropped into
    /// ended up.
    ///
    /// Each move is expressed in the numbering the PREVIOUS move produced, so
    /// every remaining source, every landing already recorded and the
    /// destination group are remapped through `moved(_:subtree:to:)` after
    /// each step. nil when any move is refused, which is the core's answer
    /// for a (destination, depth) pair that would not leave a well-formed
    /// tree.
    private func dragReorder(
        _ doc: RasterDocument, sources: [Int], drop: (at: Int, depth: Int, into: Int?)
    ) -> (document: RasterDocument, landed: [Int], into: Int?)? {
        var updated = doc
        var pending = sources
        var landed: [Int] = []
        var into = drop.into
        var anchor = drop.at
        while !pending.isEmpty {
            let from = pending.removeFirst()
            guard let bounds = updated.layerSubtree(from) else { return nil }
            let subtree = bounds.start..<bounds.end
            guard anchor <= subtree.lowerBound || anchor >= subtree.upperBound else { return nil }
            // `to` indexes the stack with the moved subtree ALREADY taken
            // out — the core's own remove-then-insert convention.
            let to = anchor <= subtree.lowerBound ? anchor : anchor - subtree.count
            // The entry is the LAST record of its own subtree, so it lands at
            // the far end of the block just spliced in, and the next entry
            // goes immediately above it — which is what preserves the dragged
            // set's order.
            let landing = to + subtree.count - 1
            // The core refuses a move that moves NOTHING (an identical
            // document would mint a phantom undo step), and `to` equal to the
            // subtree's own start at its own depth is exactly that move. One
            // member of a multi-entry drag being already in place must not
            // refuse the whole drag, so it is skipped: every remap below is
            // the identity for it, and `landing` is where it already sits.
            if to == subtree.lowerBound, updated.layerDepth(from) == drop.depth {
                landed.append(landing)
                anchor = landing + 1
                continue
            }
            guard let next = updated.moveLayerTo(from: from, to: to, depth: drop.depth)
            else { return nil }
            pending = pending.map { Self.moved($0, subtree: subtree, to: to) }
            landed = landed.map { Self.moved($0, subtree: subtree, to: to) }
            into = into.map { Self.moved($0, subtree: subtree, to: to) }
            landed.append(landing)
            anchor = landing + 1
            updated = next
        }
        return (updated, landed, into)
    }

    /// Where index `i` ends up after a `moveLayerTo` that relocated the
    /// half-open range `subtree` to post-removal index `to` — the arithmetic
    /// the core itself performs (drain the block, splice it back in),
    /// mirrored here because each move renumbers the indices the NEXT move is
    /// expressed in.
    private static func moved(_ i: Int, subtree: Range<Int>, to: Int) -> Int {
        if subtree.contains(i) { return to + (i - subtree.lowerBound) }
        let removed = i >= subtree.upperBound ? i - subtree.count : i
        return removed >= to ? removed + subtree.count : removed
    }
}

// MARK: - Row double-click and right-click menu

extension LayersPanelViewController: NSMenuDelegate {
    /// Double-click on a row: reopen whatever the layer was made from. The
    /// first click has already selected the row, so this only has to route.
    @objc func rowDoubleClicked(_ sender: Any?) {
        guard let idx = layerIndex(forRow: tableView.clickedRow) else { return }
        editLayerSource(idx)
    }

    /// Builds the row menu for the row under the cursor.
    ///
    /// A right-click on a row that is ALREADY selected leaves the selection
    /// alone — otherwise the menu would collapse a multi-selection the user
    /// built precisely so a set command could act on it. A right-click
    /// anywhere else replaces the selection with that row, so the menu, the
    /// footer and the Layer menu still always act on the same thing. A
    /// right-click below the last row (clickedRow == -1) leaves the menu
    /// empty, which shows nothing.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, let idx = layerIndex(forRow: row) else { return }
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let rename = NSMenuItem(
            title: "Rename", action: #selector(renameClickedLayer(_:)), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        // Only on a live photo layer, where it is the row's own version of
        // the double-click: no other row kind has a frame to select.
        if document?.doc?.livePhotoPayload(idx) != nil {
            let frame = NSMenuItem(
                title: "Select Frame…", action: #selector(selectClickedLayerFrame(_:)),
                keyEquivalent: "")
            frame.target = self
            menu.addItem(frame)
        }
        menu.addItem(.separator())
        // Structure — the same nil-target actions the Layer menu sends, so
        // they inherit the editor's validation (Group needs a selection
        // sharing one parent, Ungroup needs a group).
        menu.addItem(
            NSMenuItem(
                title: "Group Layers",
                action: #selector(EditorViewController.groupLayers(_:)), keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(
                title: "Ungroup Layers",
                action: #selector(EditorViewController.ungroupLayers(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(lockSubmenuItem())
        menu.addItem(.separator())
        // Layer Style — the same nil-target actions the Layer > Layer Style
        // submenu sends, valid because the row was just selected, so they
        // inherit the editor's validation (no adjustment layers; Copy/Clear
        // only on a styled layer; Paste only with a copied style).
        menu.addItem(
            NSMenuItem(
                title: "Layer Style…",
                action: #selector(EditorViewController.layerStyle(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Copy Layer Style",
                action: #selector(EditorViewController.copyLayerStyle(_:)), keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(
                title: "Paste Layer Style",
                action: #selector(EditorViewController.pasteLayerStyle(_:)), keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(
                title: "Clear Layer Style",
                action: #selector(EditorViewController.clearLayerStyle(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        // The SAME nil-target action the footer button and the Layer menu
        // send, so it inherits the editor's validation: disabled on the last
        // remaining layer, and while a canvas session or sheet is open.
        menu.addItem(
            NSMenuItem(
                title: "Delete Layer",
                action: #selector(EditorViewController.deleteLayer(_:)), keyEquivalent: ""))
    }

    /// Lock ▸, the row's copy of the Layer menu's submenu: the same
    /// nil-target selectors, so the editor's validation puts the checkmarks
    /// on and disables what does not apply.
    private func lockSubmenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Lock")
        submenu.addItem(
            NSMenuItem(
                title: "Transparency",
                action: #selector(EditorViewController.lockTransparency(_:)), keyEquivalent: ""))
        submenu.addItem(
            NSMenuItem(
                title: "Pixels",
                action: #selector(EditorViewController.lockPixels(_:)), keyEquivalent: ""))
        submenu.addItem(
            NSMenuItem(
                title: "Position",
                action: #selector(EditorViewController.lockPosition(_:)), keyEquivalent: ""))
        submenu.addItem(.separator())
        submenu.addItem(
            NSMenuItem(
                title: "Lock All",
                action: #selector(EditorViewController.lockAll(_:)), keyEquivalent: ""))
        let item = NSMenuItem(title: "Lock", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Select Frame…: the clicked row's Live Photo timeline, the same picker
    /// its double-click opens. `clickedRow` still names the right row here
    /// (it stays valid until the next click), and menuNeedsUpdate has already
    /// selected it.
    @objc private func selectClickedLayerFrame(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard let idx = layerIndex(forRow: row) else { return }
        onLivePhotoEdit?(idx)
    }

    /// Rename: put the keyboard in the row's name field with the name
    /// selected, which is exactly the inline rename a click on the name
    /// starts (and commits the same way). `clickedRow` stays valid until the
    /// next click, so it still names the right row here; the selection made
    /// in menuNeedsUpdate is the fallback.
    @objc private func renameClickedLayer(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? LayerCellView
        else { return }
        cell.beginRename()
    }
}
