import AppKit

/// The ONE ordered list of phase-5 adjustment ops the three menus build
/// themselves from — Image ▸ Adjustments, Layer ▸ New Adjustment Layer and
/// the Layers panel's footer menu — so they cannot disagree about which ops
/// exist or in what order.
///
/// The legacy nine keep their own selectors (they predate the tag idiom);
/// these twelve share one selector each, the menu item's tag indexing this
/// array, exactly as `layerStyleMenu` indexes `LayerStyleEffectKind`.
enum AdjustmentMenuOrder {
    /// Photoshop's Adjustments grouping, with ours folded in: the tonal
    /// ops, then the colour ops, then the mapping ops.
    static let newOps: [AdjustmentLayerOp] = [
        .exposure,
        .vibrance,
        .hueSaturation,
        .colorBalance,
        .blackAndWhite,
        .photoFilter,
        .channelMixer,
        .colorLookup,
        .gradientMap,
        .selectiveColor,
        .shadowsHighlights,
        .whiteBalance,
    ]

    /// The op a tagged menu item names, or nil for a tag from a stale menu.
    static func op(for tag: Int) -> AdjustmentLayerOp? {
        newOps.indices.contains(tag) ? newOps[tag] : nil
    }
}

extension EditorViewController {
    /// Image ▸ Adjustments ▸ <op>: the DESTRUCTIVE twin — the same sheet,
    /// the same controls and the same core op the adjustment layer
    /// composites (`rz_image_adjust_op`), committed onto the active layer's
    /// pixels as one undo step.
    @objc func showAdjustmentSheet(_ sender: Any?) {
        guard let document = document, document.doc != nil else {
            NSSound.beep()
            return
        }
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        guard let op = AdjustmentMenuOrder.op(for: tag),
              let sheet = AdjustmentSheets.make(
                op: op, document: document, canvas: canvas, mode: .destructive)
        else {
            NSSound.beep()
            return
        }
        presentAsSheet(sheet)
    }

    /// Layer ▸ New Adjustment Layer ▸ <op> (and the panel footer's menu):
    /// the non-destructive twin, through the same path the legacy nine take.
    @objc func newAdjustmentLayerOp(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        guard let op = AdjustmentMenuOrder.op(for: tag) else {
            NSSound.beep()
            return
        }
        newAdjustmentLayer(op)
    }
}
