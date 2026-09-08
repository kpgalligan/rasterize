import AppKit

/// Layer ▸ Arrange, Align, Distribute and Link — the commands whose unit of
/// work is the SELECTION's position rather than its pixels.
///
/// Each is one core call inside one `applyEdit`, never a host loop: every
/// structural op renumbers the stack, and every move op expands its set by
/// subtree and link group, so a loop would address the wrong entries from its
/// second iteration on. The Move tool's options bar reaches the same two
/// entry points (`alignSelection` / `distributeSelection`,
/// EditorViewController+ToolOptions.swift), so the bar and the menu can never
/// mean different things.
///
/// - `arrange*` → `arrangeLayer(_:to:)`, which moves an entry among its
///   SIBLINGS only and never into or out of a group. Reordering is not a
///   position edit, so no lock refuses it — Photoshop does not block it
///   either, and blocking it would make a locked layer unmanageable.
/// - `align*` / `distribute*` → `alignLayers` / `distributeLayers`, which act
///   on CONTENT bounds (`layerBounds`) — the box of actually opaque pixels,
///   not the pixel-buffer rect, which for a canvas-sized layer are very
///   different rectangles. They MOVE, so a position lock refuses them and the
///   alert names the layer.
/// - `linkLayers` / `unlinkLayers` → `linkLayers(_:)` / `unlinkLayers(_:)`.
///   From then on the linked entries move and transform together whatever the
///   selection is, because `moveLayers` and `transformLayers` expand the set
///   by link group. Linking is a property write, not a move, so it too is
///   unaffected by the locks.
extension EditorViewController {
    // MARK: - Arrange

    @objc func bringToFront(_ sender: Any?) { arrange(RZ_ARRANGE_FRONT, "Bring to Front") }

    @objc func bringForward(_ sender: Any?) { arrange(RZ_ARRANGE_FORWARD, "Bring Forward") }

    @objc func sendBackward(_ sender: Any?) { arrange(RZ_ARRANGE_BACKWARD, "Send Backward") }

    @objc func sendToBack(_ sender: Any?) { arrange(RZ_ARRANGE_BACK, "Send to Back") }

    /// Moves the active entry among its siblings and keeps it selected at its
    /// NEW index, which the core decides — an entry that passed another
    /// subtree has renumbered everything it passed.
    ///
    /// Deliberately the PRIMARY entry alone even when several are selected:
    /// the core's op is per entry and each one renumbers, so a loop would
    /// arrange whatever moved into the next index. Photoshop's own Arrange
    /// over a multi-selection is a sequence of these, and pressing ⌘] twice
    /// is the honest way to spell it.
    private func arrange(_ how: RzArrange, _ actionName: String) {
        guard let document = document, let before = document.doc else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        // Where it will land, derived from the stack BEFORE the move: the
        // entry keeps its identity, not its address.
        let landing = before.layerTree.arrangeLanding(of: idx, how)
        document.applyEdit(actionName) { $0.arrangeLayer(idx, to: how) }
        guard document.doc !== before, let doc = document.doc else { return }
        setActiveLayer(min(max(landing, 0), doc.layerCount - 1))
    }

    /// Enabled when the active entry has a sibling to move past in that
    /// direction. Arrange stays inside a level, so "the top" means the top of
    /// its own group.
    func canArrangeLayer(up: Bool) -> Bool {
        guard let document = document, let doc = document.doc else { return false }
        let idx = document.activeLayerIndex
        let siblings = doc.layerTree.siblings(of: idx)
        return up ? siblings.contains { $0 > idx } : siblings.contains { $0 < idx }
    }

    // MARK: - Align and distribute

    @objc func alignLeft(_ sender: Any?) { alignSelection(0) }

    @objc func alignCenterX(_ sender: Any?) { alignSelection(1) }

    @objc func alignRight(_ sender: Any?) { alignSelection(2) }

    @objc func alignTop(_ sender: Any?) { alignSelection(3) }

    @objc func alignCenterY(_ sender: Any?) { alignSelection(4) }

    @objc func alignBottom(_ sender: Any?) { alignSelection(5) }

    @objc func distributeHorizontally(_ sender: Any?) { distributeSelection(0) }

    @objc func distributeVertically(_ sender: Any?) { distributeSelection(1) }

    /// The six align edges in the order the core numbers them
    /// (`RzAlign`) — which is also the order the Move tool's six options-bar
    /// segments sit in, so one table serves the menu and the bar.
    private static let alignEdges: [(edge: RzAlign, name: String)] = [
        (RZ_ALIGN_LEFT, "Align Left"),
        (RZ_ALIGN_CENTER_X, "Align Horizontal Centers"),
        (RZ_ALIGN_RIGHT, "Align Right"),
        (RZ_ALIGN_TOP, "Align Top"),
        (RZ_ALIGN_CENTER_Y, "Align Vertical Centers"),
        (RZ_ALIGN_BOTTOM, "Align Bottom"),
    ]

    /// Aligns the selection's content bounds — to the selection's own union
    /// when two or more entries are selected, and to the CANVAS when one is.
    ///
    /// That rule is the whole "align to" question, answered without a mode to
    /// set: a union of one is the layer itself, so aligning it to itself does
    /// nothing (the core refuses it outright), while "put this layer on the
    /// left edge" is exactly what one selected layer means. With several
    /// selected, aligning them to each other is Photoshop's default and the
    /// only reading that needs no reference rectangle from anywhere else.
    func alignSelection(_ index: Int) {
        guard let document = document, document.doc != nil,
              index >= 0, index < Self.alignEdges.count
        else {
            NSSound.beep()
            return
        }
        let indices = document.selectedLayerIndices
        guard !refuseLockedEdit(layers: movingIndices(indices), kind: RZ_EDIT_POSITION)
        else { return }
        let choice = Self.alignEdges[index]
        // "Two or more" is counted over the INDEPENDENT ROOTS, the same
        // reduction the core makes (`doc_align::content_boxes` →
        // `doc_structure::independent_roots`): a group selected together with
        // one of its own children is two ROWS but one box, and asking the
        // core to align a set to itself is a refusal — a bare beep — where
        // the one-row case would happily align to the canvas.
        let roots = document.doc?.layerTree.independentRoots(indices).count ?? indices.count
        document.applyEdit(choice.name) {
            $0.alignLayers(indices, edge: choice.edge, toCanvas: roots < 2)
        }
    }

    /// Equalizes the GAPS between the selection's content bounds along one
    /// axis (0 horizontal, 1 vertical), the two outermost entries staying
    /// where they are.
    func distributeSelection(_ index: Int) {
        guard let document = document, document.doc != nil, index >= 0, index < 2 else {
            NSSound.beep()
            return
        }
        let vertical = index == 1
        let indices = document.selectedLayerIndices
        guard !refuseLockedEdit(layers: movingIndices(indices), kind: RZ_EDIT_POSITION)
        else { return }
        document.applyEdit(vertical ? "Distribute Vertically" : "Distribute Horizontally") {
            $0.distributeLayers(indices, vertical: vertical)
        }
    }

    /// The entries a move over `indices` would really touch — subtrees and
    /// link groups included — so a refusal names the entry whose position
    /// lock actually stopped the call rather than the one that was clicked.
    private func movingIndices(_ indices: [Int]) -> [Int] {
        document?.doc?.movingSet(indices) ?? indices
    }

    /// Two entries are enough to align them to each other; one is enough to
    /// align it to the canvas. Either way there has to be a document — and
    /// at least one INDEPENDENT ROOT, which is the same reduction
    /// `canDistributeLayers` below explains: the rows a selection shows are
    /// not the boxes the core aligns.
    var canAlignLayers: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return !doc.layerTree.independentRoots(document.selectedLayerIndices).isEmpty
    }

    /// Distribute equalizes the GAPS between adjacent entries, so it needs at
    /// least three of them to have a gap to equalize.
    ///
    /// Counted over the INDEPENDENT ROOTS, not the selected rows: the core
    /// reduces the set exactly that way (`doc_align::content_boxes` →
    /// `doc_structure::independent_roots`), so a group selected together with
    /// two of its own children is three rows but ONE box, and enabling the
    /// item there promises something the core will refuse with a bare beep.
    /// `LayerTree.independentRoots` is the host's mirror of that reduction and
    /// is already used to predict a delete and a duplicate; this is the third
    /// prediction. (A set of three real roots where one has no opaque pixels
    /// is still a fair beep — that one the host cannot see for free.)
    var canDistributeLayers: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return doc.layerTree.independentRoots(document.selectedLayerIndices).count >= 3
    }

    // MARK: - Link

    @objc func linkLayers(_ sender: Any?) {
        guard let document = document, document.doc != nil else {
            NSSound.beep()
            return
        }
        let indices = document.selectedLayerIndices
        document.applyEdit("Link Layers") { $0.linkLayers(indices) }
    }

    @objc func unlinkLayers(_ sender: Any?) {
        guard let document = document, document.doc != nil else {
            NSSound.beep()
            return
        }
        let indices = document.selectedLayerIndices
        document.applyEdit("Unlink Layers") { $0.unlinkLayers(indices) }
    }

    /// Linking is a statement about two or more entries.
    var canLinkLayers: Bool { (document?.selectedLayerIndices.count ?? 0) >= 2 }

    /// Unlink needs at least one entry that actually carries a link id.
    var canUnlinkLayers: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return document.selectedLayerIndices.contains { doc.layerLink($0) != 0 }
    }
}
