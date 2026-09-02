import AppKit

/// Layer styles: Layer > Layer Style ▸ (Blending Options…, one item per
/// effect, Copy / Paste / Clear Layer Style), the layers panel's row menu
/// and its double-click on a plain raster row. The sheet is
/// LayerStyleSheetController; the model is LayerStyle.swift. Mirrored for
/// the agent by `set_layer_style` and `set_global_light`
/// (AgentServer+LayerStyle.swift).
///
/// There is deliberately NO scale code here: "Scale Effects" lives in the
/// core, which scales a style's pixel-valued fields inside
/// `transform_layer`, `perspective_layer` and `resize` — so Free Transform,
/// the agent's transform tools and Image Size all agree with no Swift.
extension EditorViewController {
    /// In-process clipboard for Copy / Paste Layer Style (Photoshop's is
    /// per-session too).
    static var copiedLayerStyle: LayerStyle?

    /// A style hangs off a layer's shape; an adjustment layer has none, so
    /// the core ignores styles on it and the UI refuses to offer one.
    var canEditLayerStyle: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return !doc.layerIsAdjustment(document.activeLayerIndex)
    }

    var canPasteLayerStyle: Bool {
        canEditLayerStyle && Self.copiedLayerStyle != nil
    }

    /// The cheap badge query: true means the layer renders something (the
    /// core never stores an identity style).
    var activeLayerHasStyle: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return doc.layerHasStyle(document.activeLayerIndex)
    }

    /// Layer > Layer Style > Blending Options…, the row menu's Layer Style…
    /// — the active layer's sheet, opened on its Blending Options row.
    @objc func layerStyle(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        editLayerStyle(document.activeLayerIndex, initial: nil)
    }

    /// The nine effect items: the sheet opened on that effect's row, with
    /// the effect turned on. The item's tag indexes
    /// `LayerStyleEffectKind.allCases` (AppDelegate builds the submenu in
    /// that order).
    @objc func layerStyleEffect(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        let kinds = LayerStyleEffectKind.allCases
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        guard kinds.indices.contains(tag) else {
            NSSound.beep()
            return
        }
        editLayerStyle(document.activeLayerIndex, initial: kinds[tag])
    }

    /// Opens layer `idx`'s Layer Style sheet, having made it the active
    /// layer — the panel's double-click and row menu land here with the row
    /// under the cursor, exactly as the adjustment and Live Photo paths do.
    func editLayerStyle(_ idx: Int, initial: LayerStyleEffectKind? = nil) {
        guard let document = document, let doc = document.doc,
              idx >= 0, idx < doc.layerCount, !doc.layerIsAdjustment(idx)
        else {
            NSSound.beep()
            return
        }
        // The panel's double-click bypasses menu validation, so an open
        // shape session commits here — its hidden-layer preview and the
        // sheet's live preview would otherwise fight over previewImage.
        commitShapeEditSession()
        setActiveLayer(idx)
        presentAsSheet(
            LayerStyleSheetController(
                document: document, canvas: canvas, layer: idx, initial: initial))
    }

    /// Layer > Layer Style > Copy Layer Style — the active layer's style
    /// into the in-process clipboard (validation only offers it on a styled
    /// layer).
    @objc func copyLayerStyle(_ sender: Any?) {
        guard let document = document, let doc = document.doc,
              let style = doc.layerStylePayload(document.activeLayerIndex)
        else {
            NSSound.beep()
            return
        }
        Self.copiedLayerStyle = style
    }

    /// Layer > Layer Style > Paste Layer Style — replaces the active layer's
    /// whole style. Normalized first: an identity style pastes as "no
    /// style", so pasting one onto an unstyled layer is a silent no-op
    /// (nothing to undo), never a refusal beep.
    @objc func pasteLayerStyle(_ sender: Any?) {
        guard let document = document, let doc = document.doc,
              let style = Self.copiedLayerStyle, canEditLayerStyle
        else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        let target: LayerStyle? = style.isIdentity ? nil : style
        guard target != doc.layerStylePayload(idx) else { return }
        document.applyEdit("Paste Layer Style") { try? $0.withLayerStylePayload(idx, target) }
    }

    /// Layer > Layer Style > Clear Layer Style — drops the active layer's
    /// style; the pixels are untouched (effects were never baked in).
    @objc func clearLayerStyle(_ sender: Any?) {
        guard let document = document, activeLayerHasStyle else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        document.applyEdit("Clear Layer Style") { try? $0.withLayerStylePayload(idx, nil) }
    }
}
