import AppKit

// The text tool's layer logic: clicking to open or re-open a text layer, the
// layers panel's double-click, and the commit that renders a session into a
// re-editable TEXT layer (pixels rendered by TextLayer through the layer's
// description, the description in the layer's meta, the anchor rule in
// DescribedLayer.swift). The canvas owns the on-canvas NSTextView session;
// this file owns the document side. Mirrored for the agent by
// `add_text_layer` and `edit_text_layer` (AgentServer+Text.swift).
extension EditorViewController {
    /// A text-tool click: re-open the topmost VISIBLE text layer under the
    /// point, or start a new text entry there.
    func textClicked(_ point: CGPoint) {
        // A channel is the one target that survives picking the text tool
        // (EditorViewController+Channels.refuseChannelTargetEdit): text
        // cannot be written into a channel, so the session refuses rather
        // than editing the picture while every indicator names the channel.
        guard !refuseChannelTargetEdit() else { return }
        guard let doc = document?.doc, let idx = topmostTextLayer(at: point, in: doc) else {
            canvas.beginTextSession(at: point)
            return
        }
        // A click puts the caret where it landed, so nothing is preselected.
        openTextSession(layer: idx, selectAll: false)
    }

    /// Double-clicking a TEXT layer in the layers panel: switch to the text
    /// tool and reopen the layer's description with the whole string
    /// selected, so typing replaces it and the options bar exposes the font,
    /// size, color, alignment and typography. The layer needn't be under the
    /// cursor or even visible — the panel already said which one.
    func editTextLayer(_ idx: Int) {
        guard let doc = document?.doc, doc.textPayload(idx) != nil else {
            NSSound.beep()
            return
        }
        // A click that ends an open session only ends it — the rule the
        // canvas follows too — because committing may insert a layer and
        // renumber everything above it, `idx` included.
        if canvas.hasActiveTextSession {
            canvas.commitTextSession()
            return
        }
        // The session belongs to the text tool; entering it also drops any
        // mask paint target and swaps the options bar over.
        selectTool(.text)
        openTextSession(layer: idx, selectAll: true)
    }

    /// Opens the on-canvas editor on text layer `idx`, restoring its
    /// description into the options bar and the session. Shared by the
    /// text-tool click and the layers panel's double-click.
    ///
    /// The editor stays AXIS-ALIGNED in this phase: a transformed layer
    /// opens at its anchor (the layout origin's canvas position) at natural,
    /// untransformed size, and the commit re-renders through the layer's
    /// transform. The editor's width is the layer's stored box; a legacy
    /// layer with no stored width lets the canvas default it (the pre-change
    /// rule, `TextLayer.legacyBoxWidth`); point text gets a viewport wide
    /// enough for its longest line, so a line longer than the legacy width
    /// still shows unwrapped.
    func openTextSession(layer idx: Int, selectAll: Bool) {
        // The other door into a session (the layers panel's double-click)
        // takes the same refusal as the canvas click.
        guard !refuseChannelTargetEdit() else { return }
        guard let doc = document?.doc,
              let payload = doc.textPayload(idx), let anchor = doc.describedAnchor(idx)
        else {
            NSSound.beep()
            return
        }
        // Editing a layer makes it the active one (the commit replaces its
        // content, and the panel should show what is being edited).
        // setActiveLayer is the one path that moves it: it no-ops when the
        // layer is already active and carries the Channels panel and the
        // canvas's mask display with it when it is not.
        setActiveLayer(idx)
        let width: CGFloat?
        switch payload.box {
        case let .width(w):
            width = CGFloat(w)
        case .point:
            let natural = (TextLayer.layout(payload)?.rect.width ?? 0).rounded(.up) + 1
            width = max(
                TextLayer.legacyBoxWidth(canvasWidth: CGFloat(doc.width), anchorX: anchor.x),
                natural)
        case .unspecified:
            width = nil
        }
        // The options bar reflects what is being edited, and the session
        // draws with those very parameters.
        applyTextOptions(payload)
        // Hide the layer's own raster underneath the session, or the old
        // glyphs ghost behind every edit to the string. An already-hidden
        // layer has nothing to hide: the pure op returns nil and the session
        // runs over the unmodified canvas, which is correct.
        canvas.previewImage = doc.withLayerVisible(idx, false)?.flattened()?.makeCGImage()
        canvas.beginTextSession(
            at: anchor, width: width, string: payload.string, editingLayer: idx,
            selectAll: selectAll)
    }

    /// The topmost visible layer that carries a text description and whose
    /// extent contains `point` (image pixel coordinates). Plain raster layers
    /// above it do not block the hit. Axis-aligned first cut: a rotated
    /// layer hit-tests on its bounding box.
    func topmostTextLayer(at point: CGPoint, in doc: RasterDocument) -> Int? {
        for idx in stride(from: doc.layerCount - 1, through: 0, by: -1) {
            guard let info = doc.layerInfo(idx), info.visible else { continue }
            let rect = CGRect(
                x: CGFloat(info.offsetX), y: CGFloat(info.offsetY),
                width: CGFloat(info.width), height: CGFloat(info.height))
            guard rect.contains(point), doc.textPayload(idx) != nil else { continue }
            return idx
        }
        return nil
    }

    /// Commits a text session: a NEW text layer above the active one, or the
    /// re-render of the layer the session was editing. Both are one pure
    /// document op (DescribedLayer.swift), so each is one undo step.
    /// `origin` is the session's frame origin — the layout origin's canvas
    /// position, the anchor.
    func commitTextLayer(_ payload: TextLayerPayload, origin: CGPoint, editing: Int?) {
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        let name = TextLayer.layerName(for: payload.string)

        if let idx = editing, let info = doc.layerInfo(idx), let old = doc.textPayload(idx) {
            // The axis-aligned editor cannot change the map: the layer's own
            // transform re-attaches to the edited description.
            var payload = payload
            payload.transform = old.transform
            // A point-text layer stays point text — the editor's width was
            // only its viewport (D11). A stored box wider than the editor's
            // cap (`TextLayer.maxBoxWidth` — a file from elsewhere) came
            // back AT the cap: that is the same box, not an edit.
            switch (old.box, payload.box) {
            case (.point, _):
                payload.box = .point
            case let (.width(stored), .width(session))
                where stored > TextLayer.maxBoxWidth && session == TextLayer.maxBoxWidth:
                payload.box = old.box
            default:
                break
            }
            // A re-edit never moves the origin: the editor opened exactly at
            // the layer's anchor and is not draggable, so the layer keeps its
            // EXACT anchor. Re-placing the editor's origin through the
            // whole-pixel rule would round a fractional anchor — one a
            // transform composition left behind, even under a map that has
            // snapped back to the identity — and register a phantom edit
            // that nudges the glyphs by up to half a pixel. `origin` is
            // that anchor by construction; it is only consulted should the
            // layer's anchor have become unrecoverable under the session.
            let anchor = doc.describedAnchor(idx)
                ?? DescribedLayer.placementAnchor(origin, transform: old.transform)
            // Opening a text layer and closing it unchanged (⌘Return, or a
            // tool switch) must not register an undo step or dirty the file.
            // A legacy layer's box is materialized only by a REAL edit, never
            // by an unchanged ⌘Return, so the comparison treats its
            // unspecified box as the session's; the session's payload carries
            // fraction [0, 0] by construction, and the anchor — the layer's
            // own — is re-stamped by the re-render unchanged.
            let comparable = old.box == .unspecified ? old.withBox(payload.box) : old
            guard comparable.withOriginFraction(.zero) != payload else { return }
            // The name follows the text only while it still IS the text: a
            // name the user typed themselves survives the re-edit.
            let nameFollowsText = info.name == TextLayer.layerName(for: old.string)
            document.applyEdit("Edit Text Layer") { doc in
                guard let described = doc.rerenderingDescribedLayer(
                    idx, .text(payload), anchor: anchor)
                else { return nil }
                guard nameFollowsText else { return described }
                return described.withLayerName(idx, name) ?? described
            }
            // The active layer is unchanged, so the change notification alone
            // refreshes the panel, the status bar and the layer boundary.
            return
        }

        let anchor = DescribedLayer.placementAnchor(origin, transform: .identity)
        let below = document.activeLayerIndex
        let before = document.doc
        document.applyEdit("Add Text Layer") {
            $0.addingDescribedLayer(above: below, .text(payload), anchor: anchor, name: name)
        }
        guard document.doc !== before else { return }
        // The active layer moves to the new text layer; any mask paint target
        // goes with it.
        setActiveLayer(min(below + 1, document.doc.layerCount - 1))
    }
}
