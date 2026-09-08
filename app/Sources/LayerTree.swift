import AppKit

/// One row of the layers panel, as a value.
///
/// It replaces `LayerCellView.configure`'s thirteen positional arguments:
/// the row gained a depth, a kind, a lock badge, a link marker and a
/// disclosure state in this phase, and seventeen positional arguments is a
/// call nobody can read. Built once per row in `reload()`, so a cell never
/// asks the core anything itself.
struct LayerRowModel {
    /// The entry's index in the core's bottom-first stack — an ADDRESS, and
    /// only valid for the reload that produced this row.
    let index: Int
    let info: RasterDocument.LayerInfo

    /// 0 at the top level, one more inside each enclosing group. The cell
    /// turns it into the row's indent.
    let depth: Int
    let isGroup: Bool
    /// How many entries a GROUP holds directly; 0 on a raster row. The cell
    /// shows it so a collapsed group still says how much it hides.
    let childCount: Int
    /// Whether a GROUP is drawn expanded (`open` in the core, persisted in
    /// the `.rz`). Always true on a raster row.
    let expanded: Bool

    let hasMask: Bool
    let maskEnabled: Bool
    let isText: Bool
    let isAdjustment: Bool
    let isLivePhoto: Bool
    let isShape: Bool
    let clipped: Bool
    let hasStyle: Bool
    let locks: LockFlags
    /// The entry's link-group id; 0 when unlinked.
    let link: UInt32

    /// In the selection at all…
    let isSelected: Bool
    /// …and the PRIMARY of it (the active layer), which is the one the
    /// header controls and every single-layer tool describe.
    let isPrimary: Bool

    /// Left nil by `reload()` and filled in by the cell that is actually
    /// being shown: resampling a thumbnail for a row nobody can see is the
    /// one expensive thing in a reload, and AppKit only asks for the visible
    /// ones.
    var thumbnail: NSImage?
    var maskThumbnail: NSImage?
    /// What brush/eraser would hit on this row, which the cell draws as a
    /// focus ring. `var`, like the thumbnails: the editor can retarget it
    /// between a reload and the cell being asked for.
    var paintTarget: PaintTarget

    var isLinked: Bool { link != 0 }
    var isLocked: Bool { !locks.isEmpty }
}

/// The layer stack's TREE, re-derived from the flat bottom-first entry list
/// on every panel reload — exactly as the core re-derives it on every
/// composite, and for the same reason: the structure is positional, so
/// nothing has to be kept in sync with it.
///
/// The layout, which every method here is a reading of: a GROUP's children
/// are the maximal run of entries immediately BELOW it (lower indices) at
/// greater depth, and the group entry is the LAST record of its own subtree.
/// Reversing that list is the panel's top-first row order, which puts a
/// group's row above its children — what Photoshop's panel shows.
///
/// No `rz_*` calls of its own: it is built from the `LayerInfo` values the
/// panel already reads (`RasterCore.swift` is the only home for the FFI).
struct LayerTree {
    /// Per entry, bottom-first.
    private let depths: [Int]
    private let groups: [Bool]
    private let opens: [Bool]

    var count: Int { depths.count }

    init(_ infos: [RasterDocument.LayerInfo]) {
        depths = infos.map { $0.depth }
        groups = infos.map { $0.isGroup }
        opens = infos.map { $0.open }
    }

    /// Reads the three structural facts straight from the core, one entry
    /// at a time.
    ///
    /// Deliberately NOT `compactMap` over `layerInfo`: a nil anywhere in
    /// that list would SHORTEN the arrays and silently shift every depth
    /// onto the wrong entry, which is the one failure mode a positional
    /// model must not have. These three getters answer for every index in
    /// range, so the arrays cannot come out misaligned.
    init(_ doc: RasterDocument) {
        let entries = 0..<doc.layerCount
        depths = entries.map { doc.layerDepth($0) }
        groups = entries.map { doc.layerIsGroup($0) }
        opens = entries.map { doc.layerOpen($0) }
    }

    func isValid(_ idx: Int) -> Bool { idx >= 0 && idx < count }

    func depth(of idx: Int) -> Int { isValid(idx) ? depths[idx] : 0 }

    func isGroup(_ idx: Int) -> Bool { isValid(idx) ? groups[idx] : false }

    func isOpen(_ idx: Int) -> Bool { isValid(idx) ? opens[idx] : true }

    /// The entry's subtree as a half-open range: `idx..<idx + 1` for a
    /// raster entry or an empty group, `firstChild..<idx + 1` otherwise.
    /// Its `upperBound` is where a new sibling inserted "above" this entry
    /// lands — but a HOST insertion index always comes from
    /// `RasterDocument.insertionIndex(above:)` instead, so the core stays the
    /// one definition of that rule; this range is for ROW work.
    func subtree(of idx: Int) -> Range<Int> {
        guard isValid(idx) else { return 0..<0 }
        let d = depths[idx]
        var start = idx
        while start > 0, depths[start - 1] > d { start -= 1 }
        return start..<(idx + 1)
    }

    /// The index of `idx`'s enclosing group — the first entry ABOVE it at a
    /// smaller depth — or nil at the top level.
    func parent(of idx: Int) -> Int? {
        guard isValid(idx), depths[idx] > 0 else { return nil }
        let d = depths[idx]
        var i = idx + 1
        while i < count {
            if depths[i] < d { return i }
            i += 1
        }
        return nil
    }

    /// Every enclosing group, innermost first.
    func ancestors(of idx: Int) -> [Int] {
        var chain: [Int] = []
        var current = idx
        while let up = parent(of: current) {
            chain.append(up)
            current = up
        }
        return chain
    }

    /// The top-level entry `idx` belongs to — itself when it is already at
    /// depth 0. This is what Auto-Select: Group activates.
    func topLevelAncestor(of idx: Int) -> Int {
        ancestors(of: idx).last ?? idx
    }

    /// A group's DIRECT children, bottom-first; empty for a raster entry and
    /// for an empty group.
    func children(of idx: Int) -> [Int] {
        guard isGroup(idx) else { return [] }
        let range = subtree(of: idx)
        let childDepth = depths[idx] + 1
        return range.dropLast().filter { depths[$0] == childDepth }
    }

    /// Every entry sharing `idx`'s parent, bottom-first, `idx` included.
    func siblings(of idx: Int) -> [Int] {
        guard isValid(idx) else { return [] }
        if let up = parent(of: idx) { return children(of: up) }
        return topLevel()
    }

    /// The document's top level, bottom-first.
    func topLevel() -> [Int] {
        (0..<count).filter { depths[$0] == 0 }
    }

    /// True when `ancestor`'s subtree contains `idx` (itself included).
    func contains(_ ancestor: Int, _ idx: Int) -> Bool {
        subtree(of: ancestor).contains(idx)
    }

    /// Leaf entries only — what "3 layers" in the panel footer counts, and
    /// what `get_document` reports as `pixel_layer_count`. `layer_count`
    /// keeps its old meaning of addressable ENTRIES, groups included.
    var pixelLayerCount: Int { groups.filter { !$0 }.count }

    /// The panel's rows, TOP-FIRST. With `collapsedHidden` (the panel's
    /// case) a closed group's whole subtree is skipped, so a group hides its
    /// children without the model changing at all.
    func visibleRows(collapsedHidden: Bool = true) -> [Int] {
        var rows: [Int] = []
        var i = count - 1
        while i >= 0 {
            rows.append(i)
            if collapsedHidden, groups[i], !opens[i] {
                // Jump past the whole subtree: its children sit immediately
                // below it, so the first one is the subtree's lower bound.
                i = subtree(of: i).lowerBound - 1
            } else {
                i -= 1
            }
        }
        return rows
    }

    /// The row that STANDS FOR `idx` when the panel is drawn: the entry
    /// itself when its row is visible, otherwise the OUTERMOST closed
    /// ancestor — the row the user can actually see and click. (Not the
    /// top-level ancestor: with an open group holding a closed one, the
    /// closed inner group is the visible row.)
    func visibleRow(for idx: Int) -> Int {
        ancestors(of: idx).reversed().first { !isOpen($0) } ?? idx
    }

    /// Where entry `idx` ends up after `arrangeLayer(idx, to: how)`.
    ///
    /// Derived from the BEFORE tree, and exactly derivable: an arrange keeps
    /// every depth and every count and only moves the entry's own subtree
    /// among its siblings, so the enclosing group's index — and therefore
    /// the level's bounds — cannot move.
    func arrangeLanding(of idx: Int, _ how: RzArrange) -> Int {
        guard isValid(idx) else { return idx }
        let mine = subtree(of: idx)
        let level = siblings(of: idx)
        let enclosing = parent(of: idx)
        switch how {
        case RZ_ARRANGE_FRONT:
            // The top of the level: just under the enclosing group, or the
            // top of the stack.
            return (enclosing ?? count) - 1
        case RZ_ARRANGE_BACK:
            // The bottom of the level, so the entry closes its own subtree
            // starting there.
            let start = enclosing.map { subtree(of: $0).lowerBound } ?? 0
            return start + mine.count - 1
        case RZ_ARRANGE_FORWARD:
            guard let next = level.first(where: { $0 > idx }) else { return idx }
            return idx + subtree(of: next).count
        default:
            guard let previous = level.last(where: { $0 < idx }) else { return idx }
            return idx - subtree(of: previous).count
        }
    }

    /// The given entries with every one that falls inside ANOTHER given
    /// entry's subtree dropped, ascending — the core's own
    /// `doc_structure::independent_roots`, mirrored here because the host has
    /// to predict what the core will do to a selection.
    ///
    /// Duplicate, delete, align and distribute all reduce their input this
    /// way: a group already carries its children, so naming a group AND one
    /// of its children names one thing, not two. A host that counts the raw
    /// selection instead reports the wrong landing, enables a command the
    /// core refuses, or moves a layer twice.
    func independentRoots(_ indices: [Int]) -> [Int] {
        var roots: [Int] = []
        // A subtree ENDS with its own entry, so an ancestor always has the
        // higher index: walking down from the top, an entry is subsumed
        // exactly when it falls inside a root already kept.
        for idx in Set(indices).sorted().reversed() where isValid(idx) {
            if roots.contains(where: { contains($0, idx) }) { continue }
            roots.append(idx)
        }
        return roots.reversed()
    }

    /// How many ENTRIES a removal of `indices` would actually take: the sizes
    /// of its independent roots' subtrees. Deleting a group takes its whole
    /// subtree, and a selection holding a group and one of its children takes
    /// the group's subtree once — which is why counting the selection is not
    /// the same question.
    func removalCount(_ indices: [Int]) -> Int {
        independentRoots(indices).reduce(0) { $0 + subtree(of: $1).count }
    }

    /// Where `duplicateLayers(indices)`' copies land, ascending and paired
    /// with the INDEPENDENT ROOTS of `indices` — the entries the core will
    /// actually copy, which is not always the entries that were asked for.
    ///
    /// Each copy sits immediately above its source's whole subtree, and every
    /// copy inserted BELOW a later source pushes that source — and its own
    /// copy — up by exactly its own size. Reducing to independent roots first
    /// is what makes that arithmetic true: the core drops an entry subsumed by
    /// another given entry's subtree, so counting it would shift every later
    /// landing and name entries the duplicate never touched.
    func duplicateLandings(_ indices: [Int]) -> [Int] {
        var shift = 0
        return independentRoots(indices).map { idx in
            let subtree = subtree(of: idx)
            let landing = subtree.upperBound + shift + subtree.count - 1
            shift += subtree.count
            return landing
        }
    }

    /// Where the copy that CARRIES `idx` lands after
    /// `duplicateLayers(indices)`: `idx`'s own copy when it is an independent
    /// root of the selection, and otherwise the copy of the root that
    /// subsumes it — a child selected together with its group is not copied
    /// on its own, it rides inside the group's copy. nil when the selection
    /// does not cover `idx` at all.
    func duplicateLanding(of idx: Int, in indices: [Int]) -> Int? {
        let roots = independentRoots(indices)
        guard let position = roots.firstIndex(where: { contains($0, idx) }) else { return nil }
        return duplicateLandings(indices)[position]
    }

    /// Whether every enclosing group of `idx` is expanded — i.e. whether the
    /// entry has a row at all.
    func isRowVisible(_ idx: Int) -> Bool {
        ancestors(of: idx).allSatisfy { isOpen($0) }
    }
}

extension RasterDocument {
    /// The stack's structure as a value, for the panel and for the paths
    /// that need a parent chain or a subtree.
    var layerTree: LayerTree { LayerTree(self) }

    /// The entries that CONTRIBUTE to the projection: every ENTRY — leaf or
    /// group — whose own `visible` is true and whose every enclosing group is
    /// visible.
    ///
    /// It is the core's own Merge Visible predicate (`doc_structure::
    /// contributing`), mirrored here for the two things only the host needs —
    /// whether the menu item should be enabled, and where the merged layer
    /// landed — and written ONCE so those two can never disagree with each
    /// other. The core is still the authority on the edit itself.
    ///
    /// It marks GROUPS too, exactly as `mark_level` does, and that is
    /// load-bearing: `merge_visible` takes its SLOT from the bottom-most
    /// contributing ENTRY, which may be a visible group holding nothing
    /// visible, and removes an entry only when its WHOLE subtree contributed.
    /// A leaf-only mirror would answer with the wrong index whenever such a
    /// group sits below the merge.
    func contributingEntries() -> [Int] {
        let tree = layerTree
        return (0..<layerCount).filter { idx in
            guard layerInfo(idx)?.visible == true else { return false }
            return tree.ancestors(of: idx).allSatisfy { layerInfo($0)?.visible == true }
        }
    }

    /// The contributing entries that are LEAVES. The core's floor counts
    /// these, not entries: counting group rows would let a single layer
    /// inside one visible group satisfy a "two entries" test and merge itself
    /// into a copy of itself.
    func contributingLeaves() -> [Int] {
        let tree = layerTree
        return contributingEntries().filter { !tree.isGroup($0) }
    }

    /// Whether removing `indices` would leave the document with anything in
    /// it — the core's own floor (`remove_layers` refuses a removal that
    /// would empty the stack), asked about what the removal really TAKES.
    ///
    /// That is not the number of selected rows: deleting a group takes its
    /// whole subtree, and a group selected together with one of its own
    /// children takes that subtree once. The ONE definition, so the menu
    /// item's validation and the panel's trash button cannot disagree.
    func removalLeavesLayers(_ indices: [Int]) -> Bool {
        let taken = layerTree.removalCount(indices)
        return taken > 0 && taken < layerCount
    }

    /// The index `mergeVisible()` leaves the merged layer at: the slot of the
    /// bottom-most contributing ENTRY's top-level ancestor, counted against
    /// the entries that SURVIVE below it. nil when fewer than two LEAVES
    /// contribute, which is exactly when the core refuses the merge.
    func mergeVisibleLanding() -> Int? {
        let contributing = Set(contributingEntries())
        let tree = layerTree
        guard contributing.filter({ !tree.isGroup($0) }).count >= 2,
              let bottom = contributing.min()
        else { return nil }
        let anchorStart = tree.subtree(of: tree.topLevelAncestor(of: bottom)).lowerBound
        // The core removes an entry only when it contributed AND its whole
        // subtree did; everything else survives to hold what did not. An
        // EMPTY group's subtree is just itself, so a visible empty group is
        // removed and a hidden one survives — both the same as the core.
        func survives(_ idx: Int) -> Bool {
            guard contributing.contains(idx) else { return true }
            return !tree.subtree(of: idx).allSatisfy { contributing.contains($0) }
        }
        return (0..<anchorStart).filter(survives).count
    }
}
