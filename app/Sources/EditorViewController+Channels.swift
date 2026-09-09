import AppKit

/// The Channels tab's half of the editor: the paint/edit target beyond the
/// layer and its mask, the canvas's plane-and-rubylith display, the coverage
/// stroke commit for all three coverage targets, and the Image > Channels
/// menu commands.
///
/// DISPLAY VS. EDIT — the one rule worth stating twice. With a colour plane
/// targeted the canvas shows the COMPOSITE's plane in grayscale, while
/// painting, filtering and adjusting edit the ACTIVE LAYER's plane. That is
/// Photoshop's behaviour, and on the single-layer documents this feature is
/// mostly used on they are the same pixels. An alpha channel has no such
/// split: it is document state, shown and edited as itself.
extension EditorViewController {
    // MARK: - Target

    /// True when a stroke should land on a coverage target — the active
    /// layer's mask, one of its colour planes, or a document channel — with
    /// the choice confirmed against the live document. Replaces the
    /// mask-only `paintsActiveMask`.
    var paintsCoverageTarget: Bool {
        guard let document = document, let doc = document.doc else { return false }
        switch paintTarget {
        case .layer:
            return false
        case .mask:
            return doc.layerHasMask(document.activeLayerIndex)
        case .plane(let plane):
            return PaintTarget.paintablePlanes.contains(plane)
        case .channel(let index):
            return index >= 0 && index < doc.channelCount
        }
    }

    /// Drops a `.channel` target whose index is not a channel of this
    /// document back to `.layer`; every other target passes through
    /// untouched. The range check for a target being CHOSEN — an index that
    /// has just been named is at whatever position it names.
    func channelTargetClamped(_ target: PaintTarget) -> PaintTarget {
        guard case .channel(let index) = target else { return target }
        let count = document?.doc?.channelCount ?? 0
        return (index >= 0 && index < count) ? target : .layer
    }

    /// Drops a target the CURRENT TOOL cannot reach back to the layer.
    ///
    /// Only brush and eraser paint COVERAGE. Text, clone, dodge and the four
    /// retouching tools (the two healing brushes, Patch, Red Eye) rewrite
    /// whole pixels, so a mask or a colour-plane target means nothing to
    /// them; fill and gradient DO reach a colour plane and a channel
    /// (EditorViewController+PlanePaint), so they drop only a mask target. A
    /// CHANNEL target is exempt outright: it is document state rather than a
    /// property of the layer these tools rewrite, so its row stays selected —
    /// with its Duplicate / Delete / Options / Invert commands live —
    /// whatever tool is picked, and the edit is REFUSED rather than
    /// redirected: `onStrokeBegin` for a clone, dodge or healing stroke,
    /// `refuseChannelTargetEdit` for a text session and for the Patch and Red
    /// Eye commits, none of which go through a stroke at all.
    ///
    /// The rule applies on BOTH edges, the TOOL changing (`selectTool`) and
    /// the TARGET changing (`setPaintTarget`, the one writer of
    /// `paintTarget`), because one edge alone leaves the other order broken:
    /// picking the Clone Stamp or Dodge/Burn and THEN clicking the Red row
    /// used to leave `.plane(.red)` standing, and the stroke — unable to
    /// reach a plane — rewrote all three of the layer's colour planes while
    /// the status bar, the row's ring and the canvas all named Red. With both
    /// edges coerced, the target the indicators name is the only thing a
    /// stroke can reach, whichever order the two were picked in.
    func toolReachableTarget(_ target: PaintTarget) -> PaintTarget {
        guard !target.isChannel else { return target }
        if target.isCoverage,
           currentTool == .text || currentTool == .clone || currentTool == .dodge
               || currentTool == .heal || currentTool == .spotHeal
               || currentTool == .patch || currentTool == .redEye {
            return .layer
        }
        if target == .mask, currentTool == .fill || currentTool == .gradient {
            return .layer
        }
        return target
    }

    /// Refuses an edit that cannot reach a `.channel` target, beeping as
    /// every other refusal does. True when the caller must stop.
    ///
    /// A channel target is exempt from `toolReachableTarget`'s coercion (it
    /// is document state, not a property of the layer these tools rewrite),
    /// so it stands whatever tool is picked — and the status bar, the row's
    /// ring and both unringed layer wells then all say the channel is the
    /// edit target. `onStrokeBegin` refuses a clone or dodge stroke there for
    /// exactly that reason; the TEXT tool never goes through a stroke at all
    /// (`ImageCanvasView.mouseDown` routes it straight to `onTextClick`), so
    /// its session has to ask here, or committing it would write a text layer
    /// into the picture under indicators that name the channel.
    func refuseChannelTargetEdit() -> Bool {
        guard paintTarget.isChannel else { return false }
        NSSound.beep()
        return true
    }

    /// Refuses a whole-LAYER pixel command while a colour plane or an alpha
    /// channel is the edit target. True when the caller must stop.
    ///
    /// Edit > Clear and Edit > Cut rewrite the ACTIVE LAYER's pixels and have
    /// no plane route of their own in this build (Cut's other half copies the
    /// layer's pixels, which a plane target does not name). With a channel
    /// targeted the status bar, the channel row's ring and both unringed
    /// layer wells all say the channel is what an edit lands on, so a bare ⌫
    /// that quietly erased part of the photograph instead is the one outcome
    /// they must not have. `validateUserInterfaceItem` disables both items
    /// here and this backstop covers any path around that; filling a plane or
    /// a channel is the Fill tool's job (EditorViewController+PlanePaint).
    func refusePlaneTargetEdit() -> Bool {
        guard paintTarget.targetsPlaneOrChannel else { return false }
        NSSound.beep()
        return true
    }

    /// The stable id of the channel a target names — 0 for every other
    /// target, and 0 for an index that names no channel.
    func channelIdentity(of target: PaintTarget) -> UInt64 {
        guard case .channel(let index) = target else { return 0 }
        return document?.doc?.channelID(index) ?? 0
    }

    /// Re-resolves the CURRENT `.channel` target against today's channel
    /// list, by the id recorded when the row was picked rather than by the
    /// position it was picked at.
    ///
    /// A delete, a duplicate inserted above it, or an undo that puts a
    /// channel back in the middle RENUMBERS every row below the change. A
    /// range check alone passes an index that now names the NEIGHBOUR, so
    /// the target ring, the status bar and the next stroke, fill, gradient,
    /// filter or Apply Image would move to a channel nobody selected — while
    /// the eye column, keyed by the same id in
    /// `ChannelsPanelViewController.resolveChannelVisibility`, correctly
    /// stayed with the channel it was set on. This is that method's
    /// single-value twin: the target follows its channel wherever it moved,
    /// and falls back to `.layer` only once the channel itself is gone.
    func channelTargetResolved() -> PaintTarget {
        guard case .channel(let index) = paintTarget else { return paintTarget }
        guard let doc = document?.doc else { return .layer }
        let id = paintTargetChannelID
        // No id recorded (a target set before any channel existed): the range
        // check is all there is to go on.
        guard id != 0 else { return channelTargetClamped(paintTarget) }
        // The common case, and the cheap one: nothing moved.
        if index >= 0, index < doc.channelCount, doc.channelID(index) == id {
            return paintTarget
        }
        guard let moved = doc.channelIndex(forID: id) else { return .layer }
        return .channel(moved)
    }

    /// The Channels panel's row selection, applied as the edit target.
    func setChannelRowTarget(_ target: PaintTarget) {
        setPaintTarget(target)
    }

    // MARK: - Display

    /// Rebuilds the canvas's plane/rubylith view from the panel's eye column
    /// and the document. Reads the CACHED projection for the colour-plane
    /// base — never `flattened()`, which re-runs the whole compositor.
    func refreshChannelDisplay() {
        guard let document = document, let doc = document.doc, let panel = channelsPanel,
              panel.isViewLoaded
        else {
            canvas.channelDisplay = nil
            return
        }
        // Re-resolved against the CURRENT channel list, so this never draws a
        // wash for an index a delete or an undo has since renumbered.
        let visibility = panel.resolvedVisibility()
        let displayBase = visibility.base
        var base: CGImage? = nil
        switch displayBase {
        case .composite:
            // The canvas draws its own projection; only washes come from here.
            base = nil
        case .plane(let plane):
            // A colour plane is document channel values replicated into
            // R=G=B, so it is tagged with the document's space — the same
            // argument the live tick in `channelDisplayDidChange` passes.
            // The two draw the same thing, and a disagreement would flicker
            // the canvas between spaces mid-drag.
            base = document.projection?.planeImage(plane.rz, maxSide: 0)?
                .makeCGImage(in: doc.colorSpace)
        case .channel(let index):
            base = doc.channelPlane(index).flatMap {
                CanvasSelection.grayImage($0, doc.width, doc.height)
            }
        case .layerMask:
            base = doc.layerPlane(document.activeLayerIndex, RZ_PLANE_MASK).flatMap {
                CanvasSelection.grayImage($0, doc.width, doc.height)
            }
        case .nothing:
            // Every eye is off: nothing is drawn, and the canvas's
            // checkerboard is the honest picture of that.
            base = nil
        }
        var overlays: [ChannelDisplay.Overlay] = []
        // The layer mask washes on Quick Mask's terms: red at 0.5 over what
        // the mask HIDES. It carries no options of its own. A row serving as
        // the BASE is not also a wash over itself.
        //
        // The wash is CLIPPED to the layer's own rect. `layerPlane` reads a
        // mask canvas-sized with 0 outside that rect (there is nothing out
        // there for a mask to reveal), so inverting it reads 255 everywhere
        // outside — and a small layer on a big canvas would veil the whole
        // picture in red while its mask hid nothing at all.
        if visibility.mask, displayBase != .layerMask,
           let coverage = doc.layerPlane(document.activeLayerIndex, RZ_PLANE_MASK),
           let placement = doc.layerPlacement(document.activeLayerIndex),
           let mask = CanvasSelection.grayImage(
            placement.clipping(PlaneAlgebra.inverted(coverage)), doc.width, doc.height)
        {
            overlays.append(.init(mask: mask, color: .systemRed, alpha: 0.5, target: .mask))
        }
        for index in visibility.channels.sorted() where displayBase != .channel(index) {
            guard let info = doc.channelInfo(index), let coverage = doc.channelPlane(index)
            else { continue }
            // Polarity is applied HERE, once: `ChannelDisplay` draws one
            // polarity and never inverts, so the app's two rubyliths agree.
            let source = info.colorIndicatesSelected ? coverage : PlaneAlgebra.inverted(coverage)
            guard let mask = CanvasSelection.grayImage(source, doc.width, doc.height) else {
                continue
            }
            overlays.append(
                .init(
                    mask: mask,
                    color: NSColor(
                        srgbRed: CGFloat(info.red) / 255, green: CGFloat(info.green) / 255,
                        blue: CGFloat(info.blue) / 255, alpha: 1),
                    alpha: CGFloat(min(max(info.opacity, 0), 1)),
                    target: .channel(index)))
        }
        let display = ChannelDisplay(
            base: base, baseKind: displayBase, replacesComposite: displayBase != .composite,
            overlays: overlays)
        canvas.channelDisplay = display.isEmpty ? nil : display
    }

    /// The document changed: the editor's one entry into the channel
    /// display, `isLive` and all.
    ///
    /// A LIVE tick arrives per mouse event of a gesture, and what it moves is
    /// the projection: a stroke, a transform drag and a move all edit layer
    /// pixels. No live gesture can touch the channel list or a channel's
    /// plane — coverage strokes ghost on the canvas and commit once, at
    /// mouse-up — so rebuilding the washes per tick would re-read, invert and
    /// rasterize a canvas-sized CGImage per visible channel on every
    /// mouse-move (~150 MB of allocation per event on a 24 MP canvas, for
    /// bytes that cannot have changed), which is exactly the cost
    /// `ImageCanvasView`'s cached `quickMaskImage` and the Channels panel's
    /// own `isLive` guard exist to avoid. So a live tick rebuilds ONLY the
    /// colour-plane base, which does track the projection, and keeps the
    /// washes it already built.
    ///
    /// The one thing that lags is the layer-mask wash under a TRANSFORM drag,
    /// which does carry the mask: it redraws in place when the gesture posts
    /// its final, non-live change. A frame of a stale wash is the right trade
    /// against a full-canvas rebuild per mouse event.
    func channelDisplayDidChange(_ note: Notification) {
        // The same reading of the flag the Channels panel makes.
        let isLive = (note.userInfo?["isLive"] as? Bool) ?? document?.isLiveEditing ?? false
        guard isLive, let display = canvas.channelDisplay,
              let panel = channelsPanel, panel.isViewLoaded,
              case .plane(let plane) = panel.visibility.base
        else {
            // Not a live tick (or nothing plane-shaped on screen): the full
            // rebuild, which is also what drops a display that has gone.
            guard !isLive else { return }
            refreshChannelDisplay()
            return
        }
        // The document's space, in lockstep with `refreshChannelDisplay`'s
        // `.plane` arm: the live tick redraws the very image that arm built.
        canvas.channelDisplay = ChannelDisplay(
            base: document?.projection?.planeImage(plane.rz, maxSide: 0)?
                .makeCGImage(in: document?.colorSpace ?? ColorProfile.sRGB),
            baseKind: .plane(plane), replacesComposite: true, overlays: display.overlays)
    }

    /// The panel's eye column changed.
    func channelViewChanged(_ visibility: ChannelVisibility) {
        refreshChannelDisplay()
    }

    // MARK: - Coverage stroke commit

    /// The one commit for every coverage stroke: the layer's mask, one of
    /// its colour planes, or a document channel. Dispatches on the target
    /// LATCHED at mouse-down, so a panel click mid-drag can never split a
    /// stroke across two targets.
    func commitCoverageOverlay(_ data: UnsafePointer<UInt8>) {
        guard let document = document, let doc = document.doc else { return }
        let idx = document.activeLayerIndex
        let width = doc.width
        let height = doc.height
        let target = strokeTarget
        guard target != .layer else { return }
        // ImageCanvasView.endStroke hands us a pointer into its own overlay
        // buffer and documents that the receiver's applyEdit consumes the
        // bytes synchronously. A PLANE target goes through
        // applyRasterizingEdit, which can run a modal alert BEFORE the
        // transform — and a canvas resize inside that nested run loop would
        // deallocate the buffer under us. One canvas-sized copy at mouse-up
        // buys the plane path the same synchronous guarantee the mask path
        // has.
        let bytes = Array(UnsafeBufferPointer(start: data, count: width * height * 4))
        // The canvas names the action for a mask stroke only; the target
        // knows the rest, so its own name wins.
        let actionName = target.strokeActionName(erasing: currentTool == .eraser, in: doc)
        // A COVERAGE stroke commits here and returns from `onStrokeEnd`
        // before `endLiveEdit`, so this is its one record point — the same
        // step a layer stroke records, with the target naming the mask, the
        // plane or the channel it landed on.
        //
        // Built through `gestureRecord`, which is `recordGesture`'s guard on
        // its own: this path commits through `applyEdit` /
        // `applyRasterizingEdit`, whose `record:` the `lastRepeatable` latch
        // makes an ordinary eager parameter, so without it every mask, plane
        // and channel stroke paid the whole polyline-to-JSON build at mouse-up
        // with nothing recording — the exact cost `endLiveEdit`'s
        // `@autoclosure` removed from the layer-stroke path.
        let record = ActionRecorder.shared.gestureRecord(strokeRecord(actionName))
        switch target {
        case .layer:
            return
        case .mask:
            guard doc.layerHasMask(idx) else {
                NSSound.beep()
                return
            }
            document.applyEdit(actionName, record: record) { current in
                bytes.withUnsafeBufferPointer { buffer -> RasterDocument? in
                    guard let base = buffer.baseAddress else { return nil }
                    return current.paintingLayerMask(idx, overlay: base, w: width, h: height)
                }
            }
        case .plane(let plane):
            // A plane stroke rewrites the layer's PIXELS, so it contradicts
            // a text/shape/Live Photo description exactly as a brush does.
            document.applyRasterizingEdit(actionName, layer: idx, record: record) { current in
                bytes.withUnsafeBufferPointer { buffer -> RasterDocument? in
                    guard let base = buffer.baseAddress else { return nil }
                    return current.paintingLayerPlane(
                        idx, plane.rz, overlay: base, w: width, h: height)
                }
            }
        case .channel(let index):
            // A channel is document state: no layer pixels change, so no
            // description is contradicted and applyEdit is the right entry.
            document.applyEdit(actionName, record: record) { current in
                bytes.withUnsafeBufferPointer { buffer -> RasterDocument? in
                    guard let base = buffer.baseAddress else { return nil }
                    return current.paintingChannel(index, overlay: base, w: width, h: height)
                }
            }
        }
    }

    // MARK: - Panel tab

    /// View > Channels (also the other panels' Channels tab).
    @objc func showChannels(_ sender: Any?) {
        layersPanelVisible = true
        showChannelsTab()
    }

    func showChannelsTab() {
        panelTab = 1
        updatePanelVisibility()
    }

    // MARK: - Menu actions (Image > Channels)

    /// New Channel: an all-zero (nothing selected) channel with the default
    /// red rubylith at 50%, named "Alpha N".
    @objc func newChannel(_ sender: Any?) {
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        guard channelBudgetAllowsOneMore(doc) else { return }
        let name = doc.nextChannelName
        let plane = [UInt8](repeating: 0, count: doc.width * doc.height)
        document.applyEdit(
            "New Channel",
            record: .channelCommand(
                "add_channel", ["name": name, "from": "empty"],
                note: "Channels panel: New Channel")
        ) {
            $0.addingChannel(name: name, plane: plane, width: doc.width, height: doc.height)
        }
    }

    @objc func duplicateChannel(_ sender: Any?) {
        guard let document = document, let doc = document.doc,
              case .channel(let index) = paintTarget
        else {
            NSSound.beep()
            return
        }
        guard channelBudgetAllowsOneMore(doc) else { return }
        document.applyEdit(
            "Duplicate Channel",
            record: Self.channelStep(
                "duplicate_channel", doc, index, note: "Channels panel: Duplicate Channel")
        ) { $0.duplicatingChannel(index) }
    }

    /// The channel budget, asked before every UI path that CREATES a channel
    /// — New Channel, Duplicate Channel, Save Selection to a new channel,
    /// Calculations to a new channel — and said out loud when it refuses.
    ///
    /// The core returns nil past either cap and `ImageDocument.applyEdit`
    /// turns that into a bare `NSSound.beep()`: the button stays lit, no row
    /// appears, and nothing on screen says the document is at its channel
    /// ceiling or that deleting channels is the fix. Every agent mirror of
    /// these four already explains the same refusal in-band
    /// (`channelListFullResult`), so this is only the UI catching up — the
    /// three lines `addLuminosityMasks` has always used, with `adding: 1`.
    func channelBudgetAllowsOneMore(_ doc: RasterDocument) -> Bool {
        guard let reason = doc.channelBudgetRefusal(
            width: doc.width, height: doc.height, adding: 1)
        else { return true }
        presentChannelBudgetAlert(reason)
        return false
    }

    @objc func deleteChannel(_ sender: Any?) {
        guard let document = document, case .channel(let index) = paintTarget else {
            NSSound.beep()
            return
        }
        // The target goes with the channel; syncPaintTarget would clamp it
        // anyway, this just avoids a frame of a stale ring.
        setPaintTarget(.layer)
        document.applyEdit(
            "Delete Channel",
            record: Self.channelStep(
                "delete_channel", document.doc, index,
                note: "Channels panel: Delete Channel")
        ) { $0.removingChannel(index) }
    }

    @objc func channelOptions(_ sender: Any?) {
        guard let document = document, case .channel(let index) = paintTarget,
              let sheet = ChannelOptionsSheetController(document: document, channel: index)
        else {
            NSSound.beep()
            return
        }
        presentAsSheet(sheet)
    }

    @objc func invertChannel(_ sender: Any?) {
        guard let document = document, case .channel(let index) = paintTarget else {
            NSSound.beep()
            return
        }
        document.applyEdit(
            "Invert Channel",
            record: Self.channelStep(
                "invert_channel", document.doc, index,
                note: "Channels panel: Invert Channel")
        ) { $0.invertingChannel(index) }
    }

    /// The channels panel's inline rename, addressed by the channel's STABLE
    /// ID rather than by the row it was typed in.
    ///
    /// The field editor outlives the row: a delete, a duplicate or an undo —
    /// from the assistant, an MCP client or a menu — renumbers the list and
    /// ends editing, and the commit that follows would otherwise rename
    /// whichever channel now sits at the captured index. Resolving inside the
    /// transform reads the handle the edit is being built on, and a channel
    /// that has gone answers nil, which `applyEdit` turns into a beep with no
    /// undo step.
    func renameChannel(id: UInt64, to name: String) {
        guard let document = document else { return }
        // Named by the channel's OLD name, which is what the replay document
        // still carries — the same rule a layer rename follows.
        let record: [ActionStep] =
            (document.doc?.channelIndex(forID: id))
            .flatMap { document.doc?.channelInfo($0)?.name }
            .map {
                .channelCommand(
                    "rename_channel", ["channel": $0, "name": name],
                    note: "Channels panel: rename")
            } ?? .unrecorded("Rename Channel")
        document.applyEdit("Rename Channel", record: record) { current in
            guard let index = current.channelIndex(forID: id) else { return nil }
            return current.renamingChannel(index, name)
        }
    }

    /// A one-channel command, addressed by NAME: names survive the
    /// renumbering every channel add or delete causes, and they are what
    /// `list_channels` reports. A channel whose name cannot be read records
    /// the visible placeholder rather than an unresolvable index.
    static func channelStep(
        _ tool: String, _ doc: RasterDocument?, _ index: Int, note: String
    ) -> [ActionStep] {
        guard let name = doc?.channelInfo(index)?.name else { return .unrecorded(note) }
        return .channelCommand(tool, ["channel": name], note: note)
    }

    // MARK: - Validation

    /// Enablement for every channel, Apply Image / Calculations and
    /// Load/Save Selection item — one place, so the menu, the row menu and
    /// the panel footer agree.
    func validateChannelItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let document = document, let doc = document.doc else { return false }
        switch item.action {
        case #selector(showChannels(_:)), #selector(newChannel(_:)),
             #selector(applyImageSheet(_:)), #selector(calculationsSheet(_:)):
            return true
        case #selector(addLuminosityMasks(_:)):
            // Nine channels at once: refused by the core past either cap,
            // and the Select menu's items are all inert in Quick Mask.
            return !canvas.quickMaskActive
        case #selector(duplicateChannel(_:)), #selector(deleteChannel(_:)),
             #selector(channelOptions(_:)), #selector(invertChannel(_:)):
            guard case .channel(let index) = paintTarget else { return false }
            return index >= 0 && index < doc.channelCount
        case #selector(loadChannelAsSelection(_:)):
            // Every ROW is loadable — RGB's alpha, a colour plane, the layer
            // mask, an alpha channel — so the item is live wherever the
            // selected row stands for a plane (the ⌘-click on that same row
            // has always loaded it).
            guard !canvas.quickMaskActive else { return false }
            return selectedChannelRowSource() != nil
        case #selector(loadSelectionSheet(_:)):
            return !canvas.quickMaskActive
        case #selector(saveSelectionSheet(_:)):
            return !canvas.quickMaskActive && canvas.selection != nil
        default:
            return true
        }
    }
}
