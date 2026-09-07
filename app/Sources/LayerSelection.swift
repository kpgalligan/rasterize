import Foundation

/// The layers panel's selection: one PRIMARY entry — the layer every
/// single-layer tool acts on, and exactly what `ImageDocument
/// .activeLayerIndex` has always named — plus the other entries a SET
/// operation (move, transform, align, distribute, group, merge, delete,
/// duplicate) also acts on.
///
/// Keeping the primary a distinct, always-present member is what stops the
/// 118 existing reads of `activeLayerIndex` from being part of this phase:
/// a tool that needs one well-defined layer keeps asking for one and always
/// gets an answer, and only the paths that genuinely act on several layers
/// read `all`.
///
/// The indices are ADDRESSES, not identities (`app/CLAUDE.md`): every
/// structural op renumbers, so a selection is re-derived or re-clamped after
/// an edit rather than carried across one blindly.
struct LayerSelection: Equatable {
    /// The active layer — the one tools, panels and the status bar name.
    let primary: Int

    /// The rest of the selection. Never contains `primary`: the initializer
    /// subtracts it, so `all` can never report the same entry twice and a
    /// set op can never be handed a duplicated index (which the core refuses
    /// outright).
    let others: Set<Int>

    init(primary: Int, others: Set<Int> = []) {
        self.primary = primary
        self.others = others.subtracting([primary])
    }

    /// The ordinary case: exactly one layer selected.
    static func single(_ idx: Int) -> LayerSelection { LayerSelection(primary: idx) }

    /// Every selected entry, primary included.
    var indices: Set<Int> { others.union([primary]) }

    /// Every selected entry ASCENDING — the order the core's set ops want
    /// (`rz_doc_*_layers` takes a sorted, duplicate-free list).
    var all: [Int] { indices.sorted() }

    var count: Int { others.count + 1 }

    /// True when this is a genuine multi-selection, which is what the
    /// set-aware menu items and the panel's row drawing key on.
    var isMultiple: Bool { !others.isEmpty }

    func contains(_ idx: Int) -> Bool { idx == primary || others.contains(idx) }

    /// Prunes entries a structural edit removed and pulls the primary back
    /// into range. Called after EVERY document change: grouping, deleting
    /// and merging all renumber, and an index left dangling would silently
    /// retarget the next edit onto whatever moved into that slot.
    func clamped(to layerCount: Int) -> LayerSelection {
        guard layerCount > 0 else { return .single(0) }
        let top = layerCount - 1
        return LayerSelection(
            primary: min(max(primary, 0), top),
            others: others.filter { $0 >= 0 && $0 <= top })
    }

    /// Every member replaced by the row that STANDS FOR it in the panel — the
    /// entry itself when its row is visible, otherwise the outermost closed
    /// ancestor (`LayerTree.visibleRow(for:)`).
    ///
    /// Called when a group CLOSES over part of the selection. The panel draws
    /// the stand-in row selected either way; without this the commands kept
    /// acting on the entry that no longer has a row, so Delete Layer deleted a
    /// layer inside the group while the highlighted group survived. Collapsing
    /// several members onto one row can shrink the set, which is correct: they
    /// are one row now.
    func mappedToVisibleRows(in doc: RasterDocument) -> LayerSelection {
        let tree = doc.layerTree
        return LayerSelection(
            primary: tree.visibleRow(for: primary),
            others: Set(others.map { tree.visibleRow(for: $0) }))
    }

    /// ⇧- or ⌘-click on a row that was not selected: it joins the set and
    /// becomes the primary, which is Photoshop's behaviour (the last row
    /// touched is the one the header controls describe).
    func adding(_ idx: Int) -> LayerSelection {
        LayerSelection(primary: idx, others: indices)
    }

    /// ⌘-click on a row that WAS selected. nil when it would empty the
    /// selection — a document always has an active layer, so the caller
    /// leaves the set alone rather than clearing it.
    func removing(_ idx: Int) -> LayerSelection? {
        guard contains(idx) else { return self }
        var remaining = indices
        remaining.remove(idx)
        guard let next = remaining.max() else { return nil }
        return LayerSelection(primary: next, others: remaining)
    }
}

extension ImageDocument {
    /// Every selected entry ascending — what a set op is handed.
    var selectedLayerIndices: [Int] { layerSelection.all }

    /// Collapses the selection onto one entry (a plain click on a row, and
    /// what every existing `activeLayerIndex = idx` write already means).
    func selectLayer(_ idx: Int) {
        setLayerSelection(.single(idx))
    }

    /// ⌘-click: add the entry, or remove it when it is already in the set.
    /// A removal that would empty the selection is ignored.
    func toggleLayerInSelection(_ idx: Int) {
        if layerSelection.contains(idx) {
            if let reduced = layerSelection.removing(idx) { setLayerSelection(reduced) }
        } else {
            setLayerSelection(layerSelection.adding(idx))
        }
    }
}
