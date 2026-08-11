import Foundation

/// The adjustment ops this app can CREATE and RE-EDIT, raw values being the
/// meta `op` strings of the core's schema (core/src/adjust.rs). An op from a
/// newer schema still composites (the core parses its own meta), still
/// badges as an adjustment layer (`rz_doc_layer_is_adjustment`), and still
/// round-trips untouched through `AdjustmentLayerPayload`; only the app-side
/// dialog would be missing. Adding an op means: a case here, a dialog behind
/// `AdjustmentLayerSheetController.make`, and a menu item.
enum AdjustmentLayerOp: String, CaseIterable {
    case bcs = "bcs"
    case curves = "curves"
    case levels = "levels"
    case hueRotate = "hue_rotate"
    case posterize = "posterize"
    case threshold = "threshold"
    case invert = "invert"
    case grayscale = "grayscale"
    case sepia = "sepia"

    /// The user-facing name: the new layer's default name, and the stem of
    /// the menu item ("Brightness/Contrast/Saturation…") and the undo action
    /// ("New Levels Layer"). Matches the destructive Filters menu wherever
    /// that menu has the same op.
    var displayName: String {
        switch self {
        case .bcs: return "Brightness/Contrast/Saturation"
        case .curves: return "Curves"
        case .levels: return "Levels"
        case .hueRotate: return "Hue Rotate"
        case .posterize: return "Posterize"
        case .threshold: return "Threshold"
        case .invert: return "Invert"
        case .grayscale: return "Grayscale"
        case .sepia: return "Sepia"
        }
    }

    /// Ops with no params: created immediately, no dialog, and Adjustment
    /// Options… stays disabled for them.
    var isParameterless: Bool {
        switch self {
        case .invert, .grayscale, .sepia: return true
        case .bcs, .curves, .levels, .hueRotate, .posterize, .threshold: return false
        }
    }
}

/// The app-side view of an adjustment layer's metadata:
/// `{"type":"adjust","op":<op>,"params":{...}}` (schema and validation live
/// in core/src/adjust.rs — the CORE is the authority on whether a meta
/// composites as an adjustment; this type only reads params back into a
/// dialog and writes params a dialog produced). `params` stays a loose
/// JSON dictionary on purpose: values are heterogeneous (numbers for the
/// slider ops, point arrays for curves), and unknown ops or keys must
/// round-trip rather than error.
///
/// The app must never WRITE malformed meta — a meta the core cannot parse
/// silently turns the layer into plain raster — so every writing path
/// builds params from dialog values already confined to the schema's
/// ranges.
struct AdjustmentLayerPayload {
    /// The `type` the core's compositor interprets.
    static let typeName = "adjust"

    var op: String
    var params: [String: Any]

    init(op: String, params: [String: Any] = [:]) {
        self.op = op
        self.params = params
    }

    init(op: AdjustmentLayerOp, params: [String: Any] = [:]) {
        self.init(op: op.rawValue, params: params)
    }

    /// The op as one this app has a UI for; nil for ops from a newer schema.
    var knownOp: AdjustmentLayerOp? { AdjustmentLayerOp(rawValue: op) }

    /// A numeric parameter, defensively: missing, non-numeric, or non-finite
    /// values all read as `def` (the dialogs then clamp into their slider
    /// ranges).
    func number(_ key: String, default def: Double) -> Double {
        guard let value = (params[key] as? NSNumber)?.doubleValue, value.isFinite else {
            return def
        }
        return value
    }

    /// The JSON to store as the layer's metadata; nil only if the params
    /// somehow cannot be encoded. Keys are sorted so re-encoding unchanged
    /// values produces identical bytes (the re-edit sheet compares metas to
    /// skip no-op commits).
    func json() -> String? {
        let object: [String: Any] = [
            "type": Self.typeName, "op": op, "params": params,
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Non-throwing decode of a layer's meta. Deliberately LOOSER than the
    /// core's parse: it checks only the "adjust" shape (type + op string),
    /// not parameter ranges — range truth stays in the core, and the dialogs
    /// clamp whatever they read. nil means "not an adjustment description at
    /// all" (a text layer's meta, or a plain raster layer).
    static func decode(_ json: String) -> AdjustmentLayerPayload? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["type"] as? String == typeName,
              let op = dict["op"] as? String
        else { return nil }
        return AdjustmentLayerPayload(op: op, params: dict["params"] as? [String: Any] ?? [:])
    }
}

// MARK: - Reading and building adjustment layers on a document

extension RasterDocument {
    /// Layer `idx`'s adjustment description, or nil when its meta is absent
    /// or not adjustment-shaped. Pair with `layerIsAdjustment(_:)` — the
    /// core's authoritative check — when deciding how the layer composites;
    /// this parse is for prefilling the dialog.
    func adjustmentPayload(_ idx: Int) -> AdjustmentLayerPayload? {
        guard let meta = layerMeta(idx) else { return nil }
        return AdjustmentLayerPayload.decode(meta)
    }

    /// The chained pure ops every "new adjustment layer" path shares —
    /// creation, and the creation sheet's live preview, so what the preview
    /// shows is exactly what Apply commits. Inserts a transparent
    /// CANVAS-SIZED layer at offset (0,0) above `idx` (the compositor
    /// ignores adjustment pixels; canvas-sized pixels make the MASK
    /// canvas-sized), attaches `meta`, and always gives the layer a mask:
    /// from `selection` (a canvas-sized coverage buffer — the marquee is the
    /// caller's to keep, matching Layer > Mask > From Selection) or
    /// reveal-all when nil. One handle out, so committing it through
    /// applyEdit is one undo step.
    func addingAdjustmentLayer(
        above idx: Int, name: String, meta: String, selection: [UInt8]?
    ) -> RasterDocument? {
        let newIdx = idx + 1
        guard let added = addingLayer(above: idx, name: name),
              let described = added.withLayerMeta(newIdx, meta)
        else { return nil }
        if let selection = selection {
            return described.addingLayerMask(
                newIdx, kind: RZ_MASK_FROM_SELECTION, selection: selection)
        }
        return described.addingLayerMask(newIdx, kind: RZ_MASK_REVEAL_ALL)
    }
}
