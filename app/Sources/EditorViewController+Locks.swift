import AppKit

/// Layer ▸ Lock, the refusal alert the canvas paths use, and the ONE
/// validation entry every menu item this phase added answers through.
extension EditorViewController {
    // MARK: - Refusing a locked edit

    /// Refuses an edit that entry `idx`'s locks forbid, with a brief
    /// app-modal alert NAMING the lock; true when refused.
    ///
    /// The exact twin of `refuseAdjustmentPixelEdit()`, and for the same
    /// reason: the canvas paths — a stroke, a fill, a gradient drag, a move
    /// — are outside menu validation's reach, so without it a locked layer
    /// would simply do nothing and the user would be left guessing.
    ///
    /// The core refuses regardless of whether anyone asks it first (every op
    /// runs under `under_locks`), so this is about the MESSAGE, never about
    /// enforcement: a path that forgets to call it still cannot write.
    @discardableResult
    func refuseLockedEdit(layer idx: Int, kind: RzEditKind) -> Bool {
        guard let doc = document?.doc else { return false }
        let blocking = doc.lockBlockingFlags(idx, kind: kind)
        guard !blocking.isEmpty else { return false }
        let name = doc.layerInfo(idx)?.name ?? "this layer"
        let alert = NSAlert()
        alert.messageText = LockFlags.refusal(layerName: name, blocking: blocking)
        alert.informativeText =
            "Unlock it in Layer ▸ Lock (or the layer's row menu) to edit it."
        alert.runModal()
        return true
    }

    /// The alert a DESCRIBED-layer re-render (text, shape) gets when a
    /// TRANSPARENCY lock is what refused it — the UI twin of
    /// `AgentServer.rejectLockedRerender`, and asked AFTER the edit for the
    /// same reason: the lock only bites when the new layout changes the
    /// raster's size or offset (`doc_lock`'s rule that a frozen alpha channel
    /// cannot follow a buffer that moved), which is not knowable until the
    /// layout has run. Silent when transparency is not locked, so a genuine
    /// layout failure keeps `applyEdit`'s beep and nothing else.
    func refuseLockedRerender(layer idx: Int) {
        guard let doc = document?.doc, doc.lockFlags(idx).contains(.transparency) else { return }
        let name = doc.layerInfo(idx)?.name ?? "This layer"
        let alert = NSAlert()
        alert.messageText = "“\(name)” has its transparency locked."
        alert.informativeText =
            "Re-rendering lays the layer out again, so its raster changes size and position "
            + "— which a frozen alpha channel cannot follow. Unlock Transparency in "
            + "Layer ▸ Lock to edit it."
        alert.runModal()
    }

    /// The alert an edit that only REMOVES coverage gets when a TRANSPARENCY
    /// lock is what silently refused it — the UI twin of
    /// `AgentServer.frozenAlphaRefusal`, and asked AFTER the edit for the
    /// same reason `refuseLockedRerender` is: `refuseLockedEdit(…,
    /// RZ_EDIT_PIXELS)` cannot see it, because the transparency bit is not
    /// one of the bits `lock_block` reports for a Pixels edit. What refuses
    /// is the core's compare-after-restore latch: a clear removes coverage
    /// only, a frozen alpha puts every byte back, so the op is a byte-exact
    /// no-op and answers nil — which `applyEdit` reports as a bare beep.
    ///
    /// Call it only when the edit left the document unchanged. Silent when
    /// transparency is not locked, so a genuine refusal keeps its beep.
    func refuseFrozenAlpha(layer idx: Int) {
        guard let doc = document?.doc, doc.lockFlags(idx).contains(.transparency) else { return }
        let name = doc.layerInfo(idx)?.name ?? "This layer"
        let alert = NSAlert()
        alert.messageText = "“\(name)” has its transparency locked, so nothing was removed."
        alert.informativeText =
            "A frozen alpha channel means an edit that only takes coverage away — Clear, "
            + "Cut, Layer Via Cut, an eraser — can never change a byte. Unlock "
            + "Transparency in Layer ▸ Lock to edit it."
        alert.runModal()
    }

    /// The set version: refuses as soon as ONE entry is locked, and names
    /// that entry — a move or a transform over a selection is all-or-nothing
    /// in the core, so a partial answer would be a lie.
    @discardableResult
    func refuseLockedEdit(layers: [Int], kind: RzEditKind) -> Bool {
        guard let doc = document?.doc else { return false }
        for idx in layers where !doc.lockBlockingFlags(idx, kind: kind).isEmpty {
            return refuseLockedEdit(layer: idx, kind: kind)
        }
        return false
    }

    // MARK: - Layer ▸ Lock

    /// Each item TOGGLES its own bit over the whole selection, with the
    /// checkmark showing the PRIMARY entry's state (the same convention
    /// Enable Layer Mask uses). Lock All sets or clears all three at once —
    /// it is the three bits together, PSD's own spelling, not a fourth bit.
    @objc func lockTransparency(_ sender: Any?) { toggleLock(.transparency) }

    @objc func lockPixels(_ sender: Any?) { toggleLock(.pixels) }

    @objc func lockPosition(_ sender: Any?) { toggleLock(.position) }

    @objc func lockAll(_ sender: Any?) { toggleLock(.all) }

    private func toggleLock(_ flag: LockFlags) {
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        let on = !doc.lockFlags(document.activeLayerIndex).contains(flag)
        let name = flag == .all
            ? (on ? "Lock All" : "Unlock Layer")
            : (on ? "Lock \(flag.displayName)" : "Unlock \(flag.displayName)")
        // The resulting lock SET of the primary entry, which is what
        // `set_layer_lock` writes — the menu item toggles a bit, the tool
        // states the whole set. A multi-selection has no twin (the tool locks
        // one layer), so it records the visible placeholder.
        var primaryLocks = doc.lockFlags(document.activeLayerIndex)
        if on { primaryLocks.formUnion(flag) } else { primaryLocks.subtract(flag) }
        let record: [ActionStep] =
            document.selectedLayerIndices.count == 1
            ? .setLayerLock(primaryLocks.isEmpty ? ["none"] : primaryLocks.names)
            : .unrecorded(name)
        document.applyToSelectedLayers(name, record: record) { doc, idx in
            var locks = doc.lockFlags(idx)
            if on {
                locks.formUnion(flag)
            } else {
                locks.subtract(flag)
            }
            return doc.withLockFlags(idx, locks)
        }
    }

    /// The primary entry's locks — what the menu's checkmarks show.
    var activeLayerLocks: LockFlags {
        guard let document = document, let doc = document.doc else { return [] }
        return doc.lockFlags(document.activeLayerIndex)
    }

    // MARK: - Validation

    /// The ONE answer for every menu item this phase added.
    ///
    /// `validateUserInterfaceItem` already carries thirty-two `case
    /// #selector` arms in a frozen file; two dozen more would blow its
    /// budget on their own. So it gets a single early-out line and the whole
    /// table lives here. nil means "not one of mine" — the switch there
    /// decides as before.
    ///
    /// The properties it reads live beside their actions: grouping in
    /// `+Groups.swift`, the commands in `+MergeStamp.swift`, align /
    /// distribute / link / arrange in `+Arrange.swift`, the locks here.
    func validateStructureItem(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        switch item.action {
        case #selector(groupLayers(_:)):
            return canGroupLayers
        case #selector(ungroupLayers(_:)):
            return canUngroupLayers
        case #selector(layerViaCopy(_:)):
            return canLayerViaCopy
        case #selector(layerViaCut(_:)):
            return canLayerViaCut
        case #selector(mergeVisible(_:)):
            return canMergeVisible
        case #selector(stampVisible(_:)):
            return canStampVisible
        case #selector(bringToFront(_:)), #selector(bringForward(_:)):
            return canArrangeLayer(up: true)
        case #selector(sendBackward(_:)), #selector(sendToBack(_:)):
            return canArrangeLayer(up: false)
        case #selector(linkLayers(_:)):
            return canLinkLayers
        case #selector(unlinkLayers(_:)):
            return canUnlinkLayers
        case #selector(alignLeft(_:)), #selector(alignCenterX(_:)),
            #selector(alignRight(_:)), #selector(alignTop(_:)),
            #selector(alignCenterY(_:)), #selector(alignBottom(_:)):
            return canAlignLayers
        case #selector(distributeHorizontally(_:)), #selector(distributeVertically(_:)):
            return canDistributeLayers
        case #selector(lockTransparency(_:)):
            return validateLockItem(item, .transparency)
        case #selector(lockPixels(_:)):
            return validateLockItem(item, .pixels)
        case #selector(lockPosition(_:)):
            return validateLockItem(item, .position)
        case #selector(lockAll(_:)):
            return validateLockItem(item, .all)
        default:
            return nil
        }
    }

    /// Checkmark from the primary entry, enabled whenever there is a
    /// document — a lock is never inapplicable, it is only on or off.
    private func validateLockItem(_ item: NSValidatedUserInterfaceItem, _ flag: LockFlags)
        -> Bool
    {
        if let menuItem = item as? NSMenuItem {
            menuItem.state = activeLayerLocks.contains(flag) ? .on : .off
        }
        return document?.doc != nil
    }
}
