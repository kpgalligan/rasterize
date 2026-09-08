import AppKit

/// The layer-structure tools: groups, locks, links, align/distribute, the
/// workflow commands and Auto-Select.
///
/// | Handler | UI path it mirrors |
/// |---|---|
/// | `groupLayers` / `ungroupLayers` | Layer ▸ New Group (⌘G) / Ungroup Layers (⇧⌘G) |
/// | `setLayerLock` | Layer ▸ Lock ▸ Transparency / Pixels / Position / All |
/// | `alignLayers` / `distributeLayers` | Layer ▸ Align / Distribute, and the Move bar |
/// | `layerViaCopy` / `layerViaCut` | Layer ▸ Layer Via Copy (⌘J) / Via Cut (⇧⌘J) |
/// | `mergeVisible` / `stampVisible` | Layer ▸ Merge Visible / Stamp Visible (⇧⌥⌘E) |
/// | `arrangeLayer` | Layer ▸ Arrange ▸ Bring to Front / Forward / Backward / To Back |
/// | `autoSelectLayer` | the Move tool's Auto-Select click |
/// | `linkLayers` / `unlinkLayers` | Layer ▸ Link Layers / Unlink Layers |
/// | `setSelectedLayers` | the layers panel's ⇧/⌘-click multi-selection |
/// | `duplicateLayer` / `deleteLayer` / `mergeDown` | the panel footer, Layer ▸ Merge Down |
///
/// Two rules every handler here follows, both of which exist because a
/// structural op RENUMBERS the stack:
///
/// - it makes exactly ONE core call over the whole set, never a loop — a
///   host loop would address its second entry against a stack the first call
///   already rewrote;
/// - it reports the NEW indices back, so the next call in a script is aimed
///   at the right entries.
///
/// A set is always an EXPLICIT array of indices. None of these tools falls
/// back to the app's panel selection: an agent cannot see it, and a tool
/// whose target depends on where the user last clicked is not reproducible.
///
/// The rest of the structure work sits with the tools it belongs to, not
/// here: `rejectLockedEdit` is called by `AgentServer.performPixelEdit` for
/// every pixel-rewriting tool (and directly by the two transform handlers,
/// which are POSITION edits); `blendModeArg`'s `allowPassThrough` split
/// lives in `+Retouch.swift`; `structuralLayerIndex` — the group-accepting
/// sibling of `paintLayerIndex` — is what `+LayerStyle`, `+Distort` and
/// `+Info` look a target up with; and every handler that PLACES a new entry
/// lands it through `RasterDocument.insertionIndex(above:)`, so a layer
/// added above a group clears the whole subtree.
extension AgentServer {
    // MARK: - Shared parsing

    /// The entry a STRUCTURAL call targets, group included — the sibling of
    /// `paintLayerIndex` with no kind guard, for the tools that legitimately
    /// accept a group (its name, visibility, opacity, blend mode, mask,
    /// style, clipping and transform all mean what they mean on a layer).
    ///
    /// It accepts either spelling of the key — "layer", which the painting
    /// tools publish, or "index", which the older layer tools do — so no
    /// tool has to invent a third.
    func structuralLayerIndex(
        _ a: [String: Any], _ document: ImageDocument, key: String? = nil
    ) throws -> Int {
        let index = (key.flatMap { intArg(a, $0) })
            ?? intArg(a, "layer") ?? intArg(a, "index") ?? document.activeLayerIndex
        let count = document.doc?.layerCount ?? 0
        guard index >= 0, index < count else {
            throw ToolError(message: "Layer \(index) is out of range (0..\(count - 1))")
        }
        return index
    }

    /// The refusal every PIXEL tool gives for a group index, written once so
    /// the call sites cannot drift apart.
    ///
    /// `paintLayerIndex` throws it during the index lookup, which is the
    /// fail-safe default. The tools whose TARGET is only known after the rest
    /// of the arguments are parsed call it themselves instead, once the target
    /// is resolved: a group has no pixels, but its canvas-sized MASK and the
    /// document's CHANNELS are perfectly good things to paint or filter on
    /// one, and refusing those during the lookup made the one edit that shapes
    /// a group mask unreachable over MCP while the UI did it happily. The UI's
    /// gate is the same shape — `EditorViewController.onStrokeBegin` refuses a
    /// group only when the target is the layer itself.
    func rejectGroupPixelEdit(_ document: ImageDocument, _ index: Int) throws {
        guard document.doc?.layerIsGroup(index) == true else { return }
        throw ToolError(
            message: "Layer \(index) is a group: it has no pixels of its own to edit. "
                + "Target one of the layers inside it — get_document lists a group's "
                + "children. (A group's own mask IS paintable: add_layer_mask on the group, "
                + "then stroke it with target \"mask\".)")
    }

    /// `get_document`'s note about how to read the layers array. It says the
    /// linearization out loud — a group's children come BEFORE it — and it
    /// distinguishes the two rectangles every row now carries, because they
    /// are DIFFERENT rectangles on both kinds of row.
    ///
    /// The wording follows the C header's, which is the fact: a group row's
    /// width/height/offset_x/offset_y are the union of its raster descendants'
    /// BUFFER rects (`rz_doc_layer_offset_x`'s contract), not its content box
    /// — a group holding one canvas-sized transparent adjustment layer reports
    /// 0,0,canvas and carries no content_* keys at all. Saying they "repeat
    /// its content box" sent an agent to the wrong rectangle in exactly the
    /// case content_* was added to close.
    static let layerListNote =
        "index 0 is the bottom layer; a group's children come BEFORE it in this array and "
        + "name it in parent, so the order is bottom-first, children before their group; "
        + "width/height/offset_x/offset_y are the PIXEL BUFFER rect — the layer's own on a "
        + "raster row, the union of its raster descendants' on a group row, which is a "
        + "DIFFERENT rectangle from the content box on both; content_x/y/width/height are "
        + "the box of actually opaque pixels on either kind of row and are what "
        + "align_layers, distribute_layers and distort_layer act on, omitted when nothing "
        + "is opaque; offsets are from the canvas top-left, y down"

    /// A tool's explicit list of layer indices.
    ///
    /// Duplicates are an ERROR, not a silent dedupe: a repeat means the
    /// caller has miscounted, and quietly collapsing it would hide the
    /// miscount behind a plausible-looking success. The core refuses a
    /// repeating list for the same reason.
    func layerIndices(
        _ a: [String: Any], _ document: ImageDocument, _ key: String = "layers",
        minimum: Int = 1
    ) throws -> [Int] {
        guard let raw = a[key] as? [Any], !raw.isEmpty else {
            throw ToolError(message: "\(key) must be a non-empty array of layer indices")
        }
        let count = document.doc?.layerCount ?? 0
        var seen: Set<Int> = []
        var indices: [Int] = []
        for entry in raw {
            guard let number = Self.finiteNumber(entry) else {
                throw ToolError(message: "\(key) must hold layer indices (integers)")
            }
            let index = Int(number)
            guard index >= 0, index < count else {
                throw ToolError(message: "Layer \(index) is out of range (0..\(count - 1))")
            }
            guard seen.insert(index).inserted else {
                throw ToolError(message: "Layer \(index) is listed twice in \(key)")
            }
            indices.append(index)
        }
        guard indices.count >= minimum else {
            throw ToolError(
                message: "\(key) needs at least \(minimum) layers (got \(indices.count))")
        }
        return indices.sorted()
    }

    /// One structural edit, off the event path like every agent edit, with
    /// the core's refusal handed back rather than thrown. False when the op
    /// answered nil — nothing would change, or the structure refused it —
    /// and rethrows anything else, so a real failure still reaches the model
    /// as an error.
    /// Internal, not private: `set_layer_properties` reports its own
    /// whole-call no-op through this pair too.
    func editStructure(
        _ document: ImageDocument, _ actionName: String,
        _ transform: (RasterDocument) -> RasterDocument?
    ) throws -> Bool {
        var refused = false
        do {
            try performGroupedEdit(document, actionName) { current in
                let out = transform(current)
                if out == nil { refused = true }
                return out
            }
        } catch let error as ToolError {
            guard refused else { throw error }
            return false
        }
        return true
    }

    /// The in-band "nothing changed" answer. Never an error: no undo step
    /// opened and no byte moved, and saying so plainly is what lets a model
    /// carry on instead of retrying the identical call.
    func structureNoOp(_ fields: [String: Any], why: String) throws -> String {
        try jsonResult(
            fields.merging([
                "ok": true, "changed": false,
                "note": "Nothing changed: \(why) No undo step was added.",
            ]) { _, shared in shared })
    }

    /// Moves the app's selection with the document and tells the UI, so the
    /// panel, the status bar and the canvas follow an agent's structural
    /// edit exactly as they follow the user's.
    private func retarget(_ document: ImageDocument, _ selection: LayerSelection) {
        document.setLayerSelection(selection)
        NotificationCenter.default.post(
            name: .imageDocumentImageDidChange, object: document, userInfo: ["isLive": false])
    }

    /// Refuses an edit that entry `idx`'s locks forbid, with a message that
    /// NAMES the lock — the agent's twin of the editor's
    /// `refuseLockedEdit(layer:kind:)` alert, sharing its wording
    /// (`LockFlags.refusal`).
    ///
    /// The core refuses regardless — every op runs under `under_locks` — so
    /// this is purely about the MESSAGE: without it a locked layer answers
    /// the generic "… failed — check the parameters", which is the one
    /// reading that is NOT true, and a model would retry the same call.
    func rejectLockedEdit(
        _ document: ImageDocument, _ idx: Int, _ kind: RzEditKind
    ) throws {
        guard let doc = document.doc else { return }
        let blocking = doc.lockBlockingFlags(idx, kind: kind)
        guard !blocking.isEmpty else { return }
        let name = doc.layerInfo(idx)?.name ?? "That layer"
        throw ToolError(
            message: LockFlags.refusal(layerName: name, blocking: blocking)
                + " Clear it with set_layer_lock {\"layer\": \(idx), \"locks\": []} first.")
    }

    /// The refusal a DESCRIBED-layer re-render (text, shape, Live Photo) gives
    /// when a TRANSPARENCY lock is what stopped it.
    ///
    /// Pixels and Lock All are refused UP FRONT by `rejectLockedEdit`, exactly
    /// as they are for every other pixel tool. Transparency cannot be: it only
    /// bites when the re-render changes the raster's size or offset — the
    /// `doc_lock` rule that a frozen alpha channel cannot follow a buffer that
    /// moved — and whether a new layout does that is not knowable until it has
    /// run. So this is asked AFTER the core refuses, in place of the generic
    /// typography or geometry message, which otherwise sent a model retrying
    /// sizes forever. It returns without throwing when transparency is not
    /// locked, and the caller then throws its own message.
    func rejectLockedRerender(_ document: ImageDocument, _ idx: Int) throws {
        guard let doc = document.doc, doc.lockFlags(idx).contains(.transparency) else { return }
        let name = doc.layerInfo(idx)?.name ?? "That layer"
        throw ToolError(
            message: "Layer “\(name)” has its transparency locked, and re-rendering it lays "
                + "the layer out again: the raster's size and position change, which a "
                + "frozen alpha channel cannot follow. Clear it with set_layer_lock "
                + "{\"layer\": \(idx), \"locks\": []} first.")
    }

    /// The SET version, for the ops that MOVE a set — a move, a transform, an
    /// align, a distribute. It refuses as soon as ONE entry of the set the
    /// core would really touch is position-locked, and names THAT entry.
    ///
    /// The set is `movingSet`'s — subtrees and link groups included — because
    /// that is the set `doc_align`'s `movable_set` checks, and these ops are
    /// all-or-nothing: one locked member refuses the whole call, so a refusal
    /// naming only the entry the caller asked for would point at the wrong
    /// layer. `align_layers` and `distribute_layers` need it most: the core
    /// makes that check UP FRONT precisely so it does not depend on which
    /// entries the arithmetic happens to move, and without this they answered
    /// "nothing would move — the layers are already aligned", which was a
    /// plausible-sounding lie.
    ///
    /// The offset SETTER is deliberately not one of these: `with_layer_offset`
    /// writes one entry's offset and never fans out to a link group
    /// (`doc_align`'s module doc). It has its own, narrower check —
    /// `rejectLockedOffset` — because the SUBTREE fan-out is real even though
    /// the link fan-out is not.
    func rejectLockedMove(_ document: ImageDocument, _ indices: [Int]) throws {
        guard let doc = document.doc else { return }
        for idx in doc.movingSet(indices) {
            try rejectLockedEdit(document, idx, RZ_EDIT_POSITION)
        }
    }

    /// The SUBTREE version, for `with_layer_offset` — the one POSITION write
    /// that fans out to a group's descendants but NOT to a link group.
    ///
    /// It must be the subtree and only the subtree, because that is exactly
    /// what the core consults: `doc_lock`'s `lock_block` ORs a group's
    /// DESCENDANTS' position bits into the answer (moving a group moves them)
    /// and never looks at a link partner. Asking the single entry instead
    /// refused in the GROUP's name for a bit that belonged to a child, and
    /// then prescribed clearing the group's locks — which the core answers
    /// with "already carries exactly those locks", leaving the model in a loop
    /// with no exit in the message. Asking `rejectLockedMove` instead would
    /// refuse for a link partner the offset write never touches.
    func rejectLockedOffset(_ document: ImageDocument, _ index: Int) throws {
        guard let doc = document.doc else { return }
        for idx in doc.layerTree.subtree(of: index) {
            try rejectLockedEdit(document, idx, RZ_EDIT_POSITION)
        }
    }

    /// What a pixel edit that the core answered nil for should say when the
    /// target layer's TRANSPARENCY lock is the reason it could not move a
    /// byte — nil when that lock is not in play, and the caller then rethrows
    /// the generic refusal it already had.
    ///
    /// A transparency lock never REFUSES a pixel edit, so `rejectLockedEdit`
    /// correctly lets one through: the core runs the edit and restores the
    /// layer's original alpha afterwards. When the edit only removed coverage
    /// — an eraser stroke, `clear_selection` — that restore makes the result
    /// byte-identical, and `doc_lock`'s purity latch then answers nil rather
    /// than minting a phantom undo step. That is deliberate and documented,
    /// but "Eraser Stroke failed — check the parameters" describes it as a
    /// caller mistake, which sends a model to re-check parameters that were
    /// right. This says what actually happened instead.
    func frozenAlphaRefusal(
        _ document: ImageDocument, _ idx: Int?, _ kind: RzEditKind, _ actionName: String
    ) -> ToolError? {
        guard kind == RZ_EDIT_PIXELS, let idx = idx, let doc = document.doc,
              doc.lockFlags(idx).contains(.transparency)
        else { return nil }
        let name = doc.layerInfo(idx)?.name ?? "That layer"
        return ToolError(
            message: "\(actionName) changed nothing, and no undo step was added. Layer "
                + "“\(name)” has its transparency locked, which freezes its alpha channel: "
                + "an edit that only removes coverage — an eraser stroke, clear_selection — "
                + "can never change a byte there, and colour painted where the layer is "
                + "already transparent is discarded. Paint inside the layer's existing "
                + "opaque pixels, or clear the lock with set_layer_lock "
                + "{\"layer\": \(idx), \"locks\": []} first.")
    }

    // MARK: - Groups

    /// Mirrors Layer ▸ New Group (⌘G).
    func groupLayers(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let indices = try layerIndices(a, document)
        let name = stringArg(a, "name") ?? "Group \(doc.layerTree.topLevel().count + 1)"
        guard let result = doc.groupLayers(indices, name: name) else {
            throw ToolError(
                message: "Those layers cannot be grouped: they must all sit in the same "
                    + "group (get_document reports each layer's parent), a group cannot be "
                    + "grouped with one of its own children, and nesting stops at ten "
                    + "levels.")
        }
        try performGroupedEdit(document, "Group Layers") { _ in result.document }
        retarget(document, .single(result.group))
        var reply: [String: Any] = [
            "ok": true,
            "group": result.group,
            // The grouped entries' NEW indices: the group's children, which
            // the core placed in the group's own subtree.
            "layers": (document.doc?.layerTree.children(of: result.group) ?? []),
            "layer_count": document.doc?.layerCount ?? 0,
            "document": summary(document),
        ]
        if !result.clearedClip.isEmpty {
            reply["cleared_clip"] = result.clearedClip
            reply["note"] =
                "The clipping mask on the bottom layer of the new group was released: the "
                + "layer it clipped to stayed outside the group."
        }
        if !result.reordered.isEmpty {
            reply["reordered"] = result.reordered
        }
        return try jsonResult(reply)
    }

    /// Mirrors Layer ▸ Ungroup Layers (⇧⌘G).
    func ungroupLayers(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try structuralLayerIndex(a, document)
        guard let doc = document.doc, doc.layerIsGroup(index), let info = doc.layerInfo(index)
        else {
            throw ToolError(
                message: "Layer \(index) is not a group. get_document reports each layer's "
                    + "kind.")
        }
        let children = doc.layerTree.children(of: index)
        // Read BEFORE the edit: ungrouping discards these outright, and a
        // model that cannot see what it lost cannot put it back.
        var discarded: [String] = []
        if doc.layerHasMask(index) { discarded.append("mask") }
        if doc.layerHasStyle(index) { discarded.append("style") }
        if info.opacity < 0.999 { discarded.append("opacity") }
        if info.blendMode != RZ_BLEND_PASS_THROUGH { discarded.append("blend_mode") }
        if doc.layerClipped(index) { discarded.append("clipped") }
        // The core's own report, captured out of the edit closure: the
        // bottom-most child was clipped to nothing inside the group, so its
        // clipping mask was RELEASED rather than silently re-pointed at
        // whatever sits below the group. The mirror of group_layers'
        // cleared_clip, and reported the same way.
        var clearedClip: [Int] = []
        let dissolved = try editStructure(document, "Ungroup Layers") { current in
            guard let result = current.ungroupLayer(index) else { return nil }
            clearedClip = result.clearedClip
            return result.document
        }
        guard dissolved else {
            return try structureNoOp(["layer": index], why: "the group could not be dissolved.")
        }
        let freed = children.map { min($0, (document.doc?.layerCount ?? 1) - 1) }
        if let primary = freed.last {
            retarget(document, LayerSelection(primary: primary, others: Set(freed)))
        }
        var reply: [String: Any] = [
            "ok": true, "layers": freed, "layer_count": document.doc?.layerCount ?? 0,
        ]
        var notes: [String] = []
        if !discarded.isEmpty {
            reply["discarded"] = discarded
            notes.append(
                "A group's children cannot carry its own \(discarded.joined(separator: ", "))"
                    + ", so \(discarded.count == 1 ? "it was" : "they were") discarded.")
        }
        if !clearedClip.isEmpty {
            reply["cleared_clip"] = clearedClip
            notes.append(
                "The clipping mask on layer \(clearedClip.map(String.init).joined(separator: ", "))"
                    + " was released: it clipped to nothing inside the group, and keeping it "
                    + "would have clipped it to the layer below the group instead.")
        }
        if !notes.isEmpty {
            reply["note"] = notes.joined(separator: " ") + " Undo restores the group."
        }
        return try jsonResult(reply)
    }

    // MARK: - Locks

    /// Mirrors Layer ▸ Lock ▸ Transparency / Pixels / Position / All.
    func setLayerLock(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try structuralLayerIndex(a, document)
        guard let raw = a["locks"] as? [Any] else {
            throw ToolError(
                message: "set_layer_lock requires locks: an array of "
                    + "\"transparency\", \"pixels\", \"position\", \"all\" or \"none\"")
        }
        var locks: LockFlags = []
        for entry in raw {
            switch (entry as? String)?.lowercased() {
            case "none": locks = []
            case "all": locks = .all
            case let name?:
                guard let flag = LockFlags.named.first(where: { $0.name == name })?.flag else {
                    throw ToolError(
                        message: "Unknown lock \"\(name)\" — use transparency, pixels, "
                            + "position, all or none")
                }
                locks.formUnion(flag)
            case nil:
                throw ToolError(message: "locks must hold strings")
            }
        }
        guard try editStructure(document, "Lock Layer", { $0.withLockFlags(index, locks) }) else {
            return try structureNoOp(
                ["layer": index, "locks": locks.names],
                why: "that layer already carries exactly those locks.")
        }
        return try jsonResult(["ok": true, "layer": index, "locks": locks.names])
    }

    // MARK: - Align and distribute

    /// Mirrors Layer ▸ Align. Acts on CONTENT bounds (`content_*` in
    /// get_document), never the pixel-buffer rect.
    func alignLayers(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let indices = try layerIndices(a, document)
        let edgeName = try requiredString(a, "edge")
        guard let edge = Self.alignEdges[edgeName] else {
            throw ToolError(
                message: "edge must be one of "
                    + Self.alignEdges.keys.sorted().joined(separator: ", ")
                    + " (got \"\(edgeName)\")")
        }
        let toCanvas = (stringArg(a, "to") ?? "layers") == "canvas"
        // Before the edit, so a position lock is reported as the lock it is
        // rather than as the "nothing would move" no-op below.
        try rejectLockedMove(document, indices)
        guard try editStructure(document, "Align Layers", {
            $0.alignLayers(indices, edge: edge, toCanvas: toCanvas)
        }) else {
            return try structureNoOp(
                ["layers": indices],
                why: "nothing would move — the layers are already aligned, or fewer than "
                    + "two INDEPENDENT boxes were named. A group and one of its own children "
                    + "are ONE box (the child is inside the subtree the group already "
                    + "moves), and an entry with no opaque pixels is no box at all; aligning "
                    + "a single box to the others is aligning it to itself. Pass "
                    + "to: \"canvas\" to align one box to the canvas instead.")
        }
        return try jsonResult(["ok": true, "moved": movedFields(document, indices)])
    }

    /// Mirrors Layer ▸ Distribute. Equalizes the GAPS between adjacent
    /// content boxes (Photoshop's "distribute spacing"), so it needs three.
    func distributeLayers(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let indices = try layerIndices(a, document, minimum: 3)
        let axis = try requiredString(a, "axis")
        guard axis == "horizontal" || axis == "vertical" else {
            throw ToolError(message: "axis must be horizontal or vertical (got \"\(axis)\")")
        }
        // As in alignLayers: the lock, not the no-op.
        try rejectLockedMove(document, indices)
        guard try editStructure(document, "Distribute Layers", {
            $0.distributeLayers(indices, vertical: axis == "vertical")
        }) else {
            return try structureNoOp(
                ["layers": indices],
                why: "nothing would move — the spacing is already even, or fewer than three "
                    + "of those layers have any opaque pixels.")
        }
        return try jsonResult(["ok": true, "moved": movedFields(document, indices)])
    }

    private static let alignEdges: [String: RzAlign] = [
        "left": RZ_ALIGN_LEFT, "horizontal_center": RZ_ALIGN_CENTER_X,
        "right": RZ_ALIGN_RIGHT, "top": RZ_ALIGN_TOP,
        "vertical_center": RZ_ALIGN_CENTER_Y, "bottom": RZ_ALIGN_BOTTOM,
    ]

    /// Where the moved entries ended up — their offsets after the edit, so a
    /// caller can check the arithmetic without a second round trip.
    private func movedFields(_ document: ImageDocument, _ indices: [Int]) -> [[String: Any]] {
        guard let doc = document.doc else { return [] }
        return indices.compactMap { index in
            guard let info = doc.layerInfo(index) else { return nil }
            return ["index": index, "offset_x": info.offsetX, "offset_y": info.offsetY]
        }
    }

    // MARK: - Links

    /// Mirrors Layer ▸ Link Layers.
    func linkLayers(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let indices = try layerIndices(a, document, minimum: 2)
        guard try editStructure(document, "Link Layers", { $0.linkLayers(indices) }) else {
            return try structureNoOp(
                ["layers": indices], why: "those layers are already linked together.")
        }
        return try jsonResult([
            "ok": true, "layers": indices,
            "link": Int(document.doc?.layerLink(indices[0]) ?? 0),
        ])
    }

    /// Mirrors Layer ▸ Unlink Layers.
    func unlinkLayers(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let indices = try layerIndices(a, document)
        guard try editStructure(document, "Unlink Layers", { $0.unlinkLayers(indices) }) else {
            return try structureNoOp(["layers": indices], why: "none of those layers is linked.")
        }
        return try jsonResult(["ok": true, "layers": indices])
    }

    // MARK: - The workflow commands

    /// Mirrors Layer ▸ Layer Via Copy (⌘J).
    func layerViaCopy(_ a: [String: Any]) throws -> String {
        try layerVia(a, cut: false)
    }

    /// Mirrors Layer ▸ Layer Via Cut (⇧⌘J).
    func layerViaCut(_ a: [String: Any]) throws -> String {
        try layerVia(a, cut: true)
    }

    private func layerVia(_ a: [String: Any], cut: Bool) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard !doc.layerIsAdjustment(index) else {
            throw ToolError(
                message: "Layer \(index) is an adjustment layer: it has no pixels of its own "
                    + "to copy. Use duplicate_layer instead.")
        }
        let name = stringArg(a, "name") ?? ((doc.layerInfo(index)?.name ?? "Layer") + " copy")
        let mask = selectionMask(document)
        let landing = doc.insertionIndex(above: index)
        // This op RASTERIZES, so a described layer loses its description —
        // performPixelEdit is what reports that to the model, exactly as a
        // paint stroke does.
        let dropped = try performPixelEdit(
            document, cut ? "Layer Via Cut" : "Layer Via Copy",
            pixelLayer: cut ? index : nil
        ) { $0.layerVia(index, mask: mask, cut: cut, name: name) }
        let created = min(landing, (document.doc?.layerCount ?? 1) - 1)
        retarget(document, .single(created))
        var reply: [String: Any] = ["ok": true, "layer": created, "name": name]
        if mask == nil {
            reply["note"] =
                "No selection was active, so the whole layer was copied. This op "
                + "rasterizes: the new layer keeps neither a text/shape description nor a "
                + "layer style — duplicate_layer keeps both."
        }
        // The shared rasterization report, so a dropped description reads
        // the same here as it does after a brush stroke.
        return try pixelEditResult(reply, layer: index, rasterized: dropped)
    }

    /// Mirrors Layer ▸ Merge Visible.
    func mergeVisible(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        // Where the merged layer will land, from the stack BEFORE the merge:
        // the slot of the bottom-most contributing layer's top-level group,
        // counted against the entries that survive below it.
        let landing = document.doc?.mergeVisibleLanding()
        guard try editStructure(document, "Merge Visible", { $0.mergeVisible() }) else {
            return try structureNoOp(
                [:],
                why: "fewer than two layers contribute to the picture — a layer inside a "
                    + "hidden group contributes nothing and is never merged away.")
        }
        let count = document.doc?.layerCount ?? 0
        if let landing = landing, landing < count { retarget(document, .single(landing)) }
        return try jsonResult([
            "ok": true, "layer": landing ?? document.activeLayerIndex, "layer_count": count,
            "document": summary(document),
        ])
    }

    /// Mirrors Layer ▸ Stamp Visible (⇧⌥⌘E).
    func stampVisible(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let above = try structuralLayerIndex(a, document, key: "above")
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let name = stringArg(a, "name") ?? "Stamp"
        let landing = doc.insertionIndex(above: above)
        guard try editStructure(document, "Stamp Visible", {
            $0.stampVisible(above: above, name: name)
        }) else {
            return try structureNoOp([:], why: "there is nothing visible to stamp.")
        }
        let created = min(landing, (document.doc?.layerCount ?? 1) - 1)
        retarget(document, .single(created))
        return try jsonResult([
            "ok": true, "layer": created, "name": name,
            "layer_count": document.doc?.layerCount ?? 0,
        ])
    }

    /// Mirrors Layer ▸ Arrange. Moves the entry among its SIBLINGS only.
    func arrangeLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try structuralLayerIndex(a, document)
        let to = try requiredString(a, "to")
        guard let how = Self.arrangeDirections[to] else {
            throw ToolError(
                message: "to must be front, forward, backward or back (got \"\(to)\")")
        }
        guard let before = document.doc else { throw ToolError(message: "Document has no image") }
        // Derived from the stack BEFORE the move — an arrange keeps every
        // depth and every count, so this is exact.
        let landing = before.layerTree.arrangeLanding(of: index, how)
        guard try editStructure(document, "Arrange Layer", { $0.arrangeLayer(index, to: how) })
        else {
            return try structureNoOp(
                ["layer": index],
                why: "that layer is already at that end of its group — arrange never moves "
                    + "a layer into or out of a group (use reorder_layer with a depth).")
        }
        retarget(document, .single(landing))
        return try jsonResult(["ok": true, "index": landing, "document": summary(document)])
    }

    private static let arrangeDirections: [String: RzArrange] = [
        "front": RZ_ARRANGE_FRONT, "forward": RZ_ARRANGE_FORWARD,
        "backward": RZ_ARRANGE_BACKWARD, "back": RZ_ARRANGE_BACK,
    ]

    /// Mirrors the Move tool's Auto-Select click: which entry a click at
    /// (x, y) would activate. Never an error when nothing is hit — a miss is
    /// an answer, and the UI's own rule is to leave the selection alone.
    func autoSelectLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard let x = doubleArg(a, "x"), let y = doubleArg(a, "y"), x.isFinite, y.isFinite
        else { throw ToolError(message: "auto_select_layer requires finite x and y") }
        let group = boolArg(a, "group") ?? false
        guard let hit = doc.layerAt(CGPoint(x: x, y: y), topLevel: group) else {
            return try jsonResult([
                "ok": true, "layer": NSNull(),
                "note": "Nothing opaque is under that point, so a Move click there would "
                    + "leave the selection alone.",
            ])
        }
        if boolArg(a, "activate") ?? true {
            retarget(document, .single(hit))
        }
        return try jsonResult([
            "ok": true, "layer": hit,
            "name": doc.layerInfo(hit)?.name ?? "",
            "kind": doc.layerIsGroup(hit) ? "group" : "layer",
        ])
    }

    /// Mirrors the layers panel's ⇧/⌘-click multi-selection: what the
    /// set-taking UI commands would act on. Not an edit — no undo step, no
    /// dirty flag — which is why it does not go through performGroupedEdit.
    func setSelectedLayers(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let indices = try layerIndices(a, document)
        let primary = intArg(a, "primary") ?? indices[indices.count - 1]
        guard indices.contains(primary) else {
            throw ToolError(message: "primary (\(primary)) must be one of the given layers")
        }
        retarget(document, LayerSelection(primary: primary, others: Set(indices)))
        // Read back, not echoed: an entry inside a collapsed group is
        // re-pointed at the row that stands for it, so the set that ends up
        // selected can be smaller than the one asked for.
        return try jsonResult([
            "ok": true, "selected_layers": document.selectedLayerIndices,
            "active_layer": document.activeLayerIndex,
        ])
    }

    // MARK: - The set-aware forms of three older tools

    /// duplicate_layer, now taking either `index` or a `layers` array. ONE
    /// core call: a loop would duplicate the wrong entries from its second
    /// iteration on, because the first insert renumbered everything above
    /// it. A group duplicates with its whole subtree.
    func duplicateLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let indices = try structuralIndices(a, document)
        // Where the copies will land, derived from the stack BEFORE the
        // edit — the sources themselves move too, so reporting the input
        // indices back would name the wrong layers.
        let landings = document.doc?.layerTree.duplicateLandings(indices) ?? []
        guard try editStructure(document, "Duplicate Layer", { $0.duplicateLayers(indices) })
        else {
            return try structureNoOp(["layers": indices], why: "the copy could not be made.")
        }
        let count = document.doc?.layerCount ?? 0
        if let primary = landings.last, primary < count { retarget(document, .single(primary)) }
        return try jsonResult([
            "ok": true, "layers": landings.filter { $0 < count }, "layer_count": count,
            "document": summary(document),
        ])
    }

    /// delete_layer, same shape. The core refuses only a removal that would
    /// leave the document with no entries at all.
    func deleteLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let indices = try structuralIndices(a, document)
        guard try editStructure(document, "Delete Layer", { $0.removeLayers(indices) }) else {
            return try structureNoOp(
                ["layers": indices],
                why: "that would delete every layer in the document, and a document always "
                    + "has at least one.")
        }
        // Collapse the selection onto ONE survivor, the same as the UI's
        // Delete Layer: the clamp alone would leave the deleted entries'
        // NUMBERS in the selection, and those now name layers nobody chose.
        retarget(
            document,
            .single(min(max(indices.first ?? 0, 0), (document.doc?.layerCount ?? 1) - 1)))
        return try jsonResult([
            "ok": true, "layer_count": document.doc?.layerCount ?? 0,
            "document": summary(document),
        ])
    }

    /// merge_down on one layer, Photoshop's Merge Layers on a `layers`
    /// array. "The layer below" is the previous SIBLING, so a merge inside a
    /// group never reaches out of it.
    func mergeDown(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        if a["layers"] != nil {
            let indices = try layerIndices(a, document, minimum: 2)
            // The merged entry replaces the lowest member's picture, so that
            // member's Pixels / Transparency locks refuse the whole merge.
            try rejectLockedEdit(document, indices[0], RZ_EDIT_MERGE)
            // …and it lands at that member's SUBTREE START, which is not its
            // index the moment the member is a group: reporting `indices[0]`
            // named an entirely different layer, and a script that edited
            // "the merged layer" edited the wrong one.
            let landing = doc.layerTree.subtree(of: indices[0]).lowerBound
            guard try editStructure(document, "Merge Layers", { $0.mergeLayers(indices) }) else {
                throw ToolError(
                    message: "Those layers cannot be merged. They must all sit in the same "
                        + "group (get_document reports each layer's parent), the LOWEST of "
                        + "them must be visible, and at least one of them has to actually "
                        + "render something — a set whose only visible member is an empty "
                        + "group has no picture to merge into.")
            }
            retarget(document, .single(landing))
            return try jsonResult([
                "ok": true, "layer": landing, "document": summary(document),
            ])
        }
        let index = try structuralLayerIndex(a, document)
        guard let below = doc.layerTree.siblings(of: index).last(where: { $0 < index }) else {
            throw ToolError(
                message: "Layer \(index) is the bottom layer of its group, so there is "
                    + "nothing below it to merge into.")
        }
        // The merge replaces the layer BELOW, so its Pixels / Transparency
        // locks refuse it and the refusal names which. The upper entry is
        // only removed, and no lock blocks a removal.
        try rejectLockedEdit(document, below, RZ_EDIT_MERGE)
        // …and it lands at that sibling's SUBTREE START, exactly as in the
        // `layers` branch above: `below` names a different layer the moment
        // the sibling is a non-empty group, and can be past the end.
        let landing = doc.layerTree.subtree(of: below).lowerBound
        guard try editStructure(document, "Merge Down", { $0.mergingDown(index) }) else {
            throw ToolError(
                message: "Merge Down failed — the layer below must be visible.")
        }
        retarget(document, .single(landing))
        return try jsonResult(["ok": true, "layer": landing, "document": summary(document)])
    }

    /// `index` or `layers`, for the three tools that accept both. The single
    /// form is the older spelling and stays the default.
    private func structuralIndices(
        _ a: [String: Any], _ document: ImageDocument
    ) throws -> [Int] {
        if a["layers"] != nil { return try layerIndices(a, document) }
        return [try structuralLayerIndex(a, document)]
    }

    // MARK: - get_document's structure fields

    /// The structure keys every `get_document` row carries, added the same
    /// additive way `text`, `shape` and `style` were.
    ///
    /// `content_*` is on EVERY row, not just group rows, and that closes a
    /// real trap: align_layers and distribute_layers act on CONTENT bounds,
    /// while a raster row's `offset_*`/`width`/`height` are its PIXEL RECT —
    /// which for a canvas-sized layer (what every paste, text layer and
    /// shape layer produces) is a completely different rectangle. Without
    /// these keys an agent computing an alignment by hand would silently
    /// disagree with the tool.
    /// Every entry's CONTENT box, in ONE bottom-up pass.
    ///
    /// `RasterDocument.layerBounds` on a GROUP unions the core's `content_box`
    /// over every raster DESCENDANT with no memoization, so asking it once per
    /// row re-swept each leaf once per enclosing group — and a `content_box`
    /// on a fully transparent canvas-sized buffer (what `new_layer` and
    /// `add_adjustment_layer` produce) costs a full `w * h` sweep. Measured on
    /// a 3000 x 2000 document holding 41 such layers, `get_document` went from
    /// 0.12 s flat to 1.10 s once they sat inside 9 nested groups, all of it on
    /// the MAIN THREAD, on the tool an agent calls most.
    ///
    /// A group's children always sit BELOW it in this bottom-first stack, so
    /// one forward pass folds each group's row out of its children's
    /// already-computed boxes: one sweep per LEAF and none per group. Union is
    /// associative, so folding through the nested groups gives exactly what
    /// the core's descendant union gives.
    static func contentBoxes(
        _ doc: RasterDocument, _ tree: LayerTree
    ) -> [(x: Int, y: Int, width: Int, height: Int)?] {
        var boxes = [(x: Int, y: Int, width: Int, height: Int)?](
            repeating: nil, count: tree.count)
        for index in 0..<tree.count {
            guard tree.isGroup(index) else {
                boxes[index] = doc.layerBounds(index)
                continue
            }
            var box: (x0: Int, y0: Int, x1: Int, y1: Int)?
            for child in tree.children(of: index) {
                guard let child = boxes[child] else { continue }
                let rect = (child.x, child.y, child.x + child.width, child.y + child.height)
                if let current = box {
                    box = (
                        min(current.x0, rect.0), min(current.y0, rect.1),
                        max(current.x1, rect.2), max(current.y1, rect.3)
                    )
                } else {
                    box = (rect.0, rect.1, rect.2, rect.3)
                }
            }
            if let box = box {
                boxes[index] = (box.x0, box.y0, box.x1 - box.x0, box.y1 - box.y0)
            }
        }
        return boxes
    }

    static func structureFields(
        _ doc: RasterDocument, _ index: Int, _ tree: LayerTree,
        contentBox: (x: Int, y: Int, width: Int, height: Int)?
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "kind": tree.isGroup(index) ? "group" : "layer",
            "depth": tree.depth(of: index),
            "parent": tree.parent(of: index) ?? NSNull(),
        ]
        if tree.isGroup(index) {
            fields["children"] = tree.children(of: index)
            fields["open"] = doc.layerOpen(index)
        }
        let locks = doc.lockFlags(index)
        if !locks.isEmpty { fields["locks"] = locks.names }
        let link = doc.layerLink(index)
        if link != 0 { fields["linked"] = Int(link) }
        if let bounds = contentBox {
            fields["content_x"] = bounds.x
            fields["content_y"] = bounds.y
            fields["content_width"] = bounds.width
            fields["content_height"] = bounds.height
        }
        return fields
    }
}
