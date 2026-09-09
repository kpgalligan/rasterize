import AppKit

/// Select > Save Selection… / Load Selection…, Image > Channels > Load
/// Channel as Selection, and the three ⌘-click gestures — a layer
/// thumbnail, a mask thumbnail, a channels-panel row.
///
/// LOADING is never an edit: the selection is view state on the canvas, so
/// nothing on that side registers undo or dirties the document (the same
/// rule Invert/Feather/Grow Selection already follow). SAVING is an edit —
/// it writes an alpha channel — and it is exactly ONE undo step whether it
/// appends a channel or combines into an existing one.
///
/// The refusal rule, applied once in `loadSelection`: an ALL-ZERO plane is
/// a legitimate source (an empty channel, a fully transparent layer, a
/// black colour plane), so it deselects rather than beeping. A beep means
/// the SOURCE itself is gone — a deleted channel, a layer index that
/// shifted under the sheet, a mask that was removed.
extension EditorViewController {
    // MARK: - Menu items

    /// Select > Save Selection…
    @objc func saveSelectionSheet(_ sender: Any?) {
        guard let document = document, document.doc != nil, canvas.selection != nil else {
            NSSound.beep()
            return
        }
        presentAsSheet(SaveSelectionSheetController(editor: self))
    }

    /// Select > Load Selection…
    @objc func loadSelectionSheet(_ sender: Any?) {
        guard let document = document, document.doc != nil else {
            NSSound.beep()
            return
        }
        presentAsSheet(LoadSelectionSheetController(editor: self))
    }

    /// Image > Channels > Load Channel as Selection (and the channels row
    /// menu / panel footer): the plane the SELECTED ROW stands for, replacing
    /// the selection. The modified variants live on the row's ⌘-click, which
    /// carries the modifiers a menu item cannot.
    ///
    /// Every row is loadable, not only an alpha channel: the RGB row loads
    /// what the picture covers, a colour-plane row loads that plane, the mask
    /// row loads the mask. `ChannelRow.selectionSource` already said so and
    /// ⌘-clicking a row already did it — but the menu item asked for a
    /// `.channel` target, so on a Red row the row menu's ONE item was
    /// permanently greyed out: a menu that could never fire.
    @objc func loadChannelAsSelection(_ sender: Any?) {
        guard let source = selectedChannelRowSource() else {
            NSSound.beep()
            return
        }
        loadSelection(from: source, mode: .replace, invert: false)
    }

    /// What the Channels panel's selected row loads — nil when the edit
    /// target names no row (`.plane(.alpha)`, or a channel that has gone).
    /// Shared with `validateChannelItem`, so the item is enabled exactly when
    /// it will work.
    func selectedChannelRowSource() -> SelectionSource? {
        guard let document = document, let doc = document.doc,
              let row = ChannelRow.forTarget(paintTarget, channelCount: doc.channelCount)
        else { return nil }
        return row.selectionSource(activeLayer: document.activeLayerIndex)
    }

    // MARK: - The one load path

    /// Loads a plane as the selection (never an edit: no undo, no dirty).
    /// The plane comes back canvas-sized from `RasterDocument.selectionPlane`,
    /// is complemented per byte when `invert` is set, and combines with
    /// whatever is already selected under the usual four-way algebra.
    ///
    /// An all-zero plane cannot become a `CanvasSelection` (its init rejects
    /// an empty region), and that is not an error: Replace and Intersect
    /// with nothing select nothing, while Add and Subtract of nothing leave
    /// the selection exactly as it was — the same four answers the agent's
    /// `applyPlaneSelection` gives, so the UI and MCP paths agree.
    ///
    /// A load is REFUSED inside Quick Mask, here rather than at each of the
    /// four entry points. `ImageCanvasView.setSelection` ends the session as
    /// a selection arrives from outside the mode, and ending it DISCARDS the
    /// buffer being painted — a mask that carries no undo step, so nothing
    /// could bring it back. That is why `validateChannelItem` greys out Load
    /// Channel as Selection and Load Selection… and why the panel's footer
    /// Load button is disabled there; the two ⌘-click gestures carry no
    /// validation of their own, so the rule lives at the path all four share.
    func loadSelection(from source: SelectionSource, mode: SelectionCombineMode, invert: Bool) {
        guard !canvas.quickMaskActive else {
            NSSound.beep()
            return
        }
        guard let document = document, let doc = document.doc,
            let plane = doc.selectionPlane(for: source)
        else {
            NSSound.beep()
            return
        }
        let bytes = invert ? PlaneAlgebra.inverted(plane) : plane
        guard
            let selection = CanvasSelection(
                shape: .mask(bytes), canvasWidth: doc.width, canvasHeight: doc.height)
        else {
            switch mode {
            case .replace, .intersect:
                // The load deselected, so it records what it DID — the same
                // `.deselect` Select ▸ Deselect and Escape record. Returning
                // before the `record` below (which describes a load that
                // produced a selection) left this outcome as a silent hole,
                // and a replay then carried the previous selection into
                // every step after it.
                if canvas.selection != nil { ActionRecorder.shared.record(.deselect) }
                canvas.setSelection(nil)
            case .add, .subtract: break
            }
            return
        }
        // An all-zero combination comes back nil here too, and deselects.
        canvas.setSelection(CanvasSelection.combine(canvas.selection, with: selection, mode: mode))
        // The command boundary for a load: `ImageCanvasView.setSelection` is
        // a per-tick setter and is deliberately not hooked (see
        // `ActionRecorder`), so each selection COMMAND records for itself.
        ActionRecorder.shared.record(
            .loadSelection(
                from: source, mode: mode.agentName, invert: invert, in: doc))
    }

    /// Writes the current selection into a channel as ONE undo step: a new
    /// channel takes the selection's coverage verbatim, an existing one
    /// combines through the same per-byte algebra a load uses.
    ///
    /// A new channel is created in the default rubylith (opaque red at half
    /// opacity — `addingChannel`'s defaults, which are Quick Mask's colour
    /// and Photoshop's), changeable afterwards in Channel Options.
    func saveSelection(to destination: SelectionDestination, mode: SelectionCombineMode) {
        guard let document = document, let doc = document.doc,
              let selection = canvas.selection
        else {
            NSSound.beep()
            return
        }
        let bytes = selection.maskBytes()
        switch destination {
        case .newChannel(let name):
            // A new channel meets the same channel budget New Channel does,
            // and answers it with the same alert rather than applyEdit's bare
            // beep (EditorViewController+Channels.channelBudgetAllowsOneMore).
            guard channelBudgetAllowsOneMore(doc) else { return }
            // The plane's size is the SELECTION's canvas, not the document's
            // one read a moment later: they are the same today (the canvas
            // drops its selection whenever the size changes), and describing
            // the bytes honestly is what lets add_channel resample rather
            // than refuse if that ever stops being true.
            let width = selection.canvasWidth
            let height = selection.canvasHeight
            document.applyEdit(
                "Save Selection",
                record: .saveSelection(to: destination, mode: mode.agentName, in: doc)
            ) { doc in
                doc.addingChannel(name: name, plane: bytes, width: width, height: height)
            }
        case .channel(let index):
            document.applyEdit(
                "Save Selection",
                record: .saveSelection(to: destination, mode: mode.agentName, in: doc)
            ) { doc in
                // Read the channel INSIDE the transform: it is the handle
                // the edit is being built on, not the one the sheet saw.
                guard let existing = doc.channelPlane(index) else { return nil }
                return doc.settingChannelData(
                    index, PlaneAlgebra.combine(existing, bytes, mode: mode))
            }
        }
    }

    // MARK: - ⌘-click gestures

    /// The layers panel's ⌘-click on a layer or mask thumbnail: the layer's
    /// transparency, or its mask. The cell only ever sends those two
    /// targets; anything else is a wiring mistake and beeps rather than
    /// guessing at a plane.
    func loadLayerSelection(layer idx: Int, target: PaintTarget, mode: SelectionCombineMode) {
        switch target {
        case .layer: loadSelection(from: .layerAlpha(idx), mode: mode, invert: false)
        case .mask: loadSelection(from: .layerMask(idx), mode: mode, invert: false)
        case .plane, .channel: NSSound.beep()
        }
    }

    /// The channels panel's ⌘-click on a row (the row decides which plane
    /// it stands for; see `ChannelRow.selectionSource`).
    func loadRowSelection(_ source: SelectionSource, mode: SelectionCombineMode) {
        loadSelection(from: source, mode: mode, invert: false)
    }
}

extension SelectionCombineMode {
    /// The four operations as both Selection IO sheets offer them, in the
    /// order the modifier convention implies: none, Shift, Option, both.
    /// One table so the two popups cannot drift apart, and so the popup
    /// index is a plain subscript at Apply time.
    static let sheetChoices: [(title: String, mode: SelectionCombineMode)] = [
        ("Replace", .replace),
        ("Add", .add),
        ("Subtract", .subtract),
        ("Intersect", .intersect),
    ]

    /// THE modifier convention, in one place: Shift adds, Option subtracts,
    /// both intersect, and with no modifier the caller's `base` applies —
    /// the options bar's mode for a marquee drag, plain Replace for a
    /// ⌘-click on a panel row, which carries no options-bar mode.
    ///
    /// Every reader of these flags calls this: `ImageCanvasView` for the
    /// selection tools, `LayerCellView` for a ⌘-click on a layer or mask
    /// thumbnail, `ChannelsPanelViewController` for a ⌘-click on a channel
    /// row. Extending the convention (a fourth operation, a re-mapping) then
    /// moves all three together, which three copies of the switch could not.
    static func from(
        _ flags: NSEvent.ModifierFlags, base: SelectionCombineMode = .replace
    ) -> SelectionCombineMode {
        switch (flags.contains(.shift), flags.contains(.option)) {
        case (true, true): return .intersect
        case (true, false): return .add
        case (false, true): return .subtract
        case (false, false): return base
        }
    }
}
