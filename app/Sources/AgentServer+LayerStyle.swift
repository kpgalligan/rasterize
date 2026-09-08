import AppKit

/// set_layer_style, set_global_light: the agent mirrors of Layer > Layer
/// Style… (Apply / Clear Layer Style) and the panes' Use Global Light edits
/// (EditorViewController+LayerStyle.swift / LayerStyleSheetController).
/// Catalog entries live in AgentCatalog.swift and the dispatch entries in
/// AgentServer.handlers — start() asserts the two agree.
extension AgentServer {
    /// set_layer_style — mirrors Layer > Layer Style… Apply and Clear Layer
    /// Style: the WHOLE style at once (idempotent); `style` null or absent
    /// clears, and so does an identity style (the core's rule). The core
    /// validates and canonicalizes; a refused style comes back in-band with
    /// the core's message, which names the offending key.
    ///
    /// A GROUP may carry a style, so this takes `structuralLayerIndex` rather
    /// than the pixel-only helper: the shape the effects hang off is the
    /// group's own rendered projection, which the compositor hands to the
    /// synthetic layer it composites the group as (`Layer::renders_style`).
    /// A styled group also composites as a UNIT — the style is one of the
    /// things that makes a Pass Through group isolate.
    func setLayerStyle(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let index = try structuralLayerIndex(a, document)
        // Mirrors the UI's validation: the compositor ignores a style on an
        // adjustment layer (it has no shape), so storing one would only
        // mislead.
        guard !doc.layerIsAdjustment(index) else {
            throw ToolError(
                message: "Layer \(index) is an adjustment layer, which has no shape for "
                    + "effects to hang off — the compositor ignores styles on it. Target a "
                    + "pixel, text or shape layer.")
        }
        let wanted = try Self.styleArgument(a["style"])
        // Validate through the core FIRST, outside any undo group: an
        // invalid style must not open one, and the core's equal-value
        // refusal is what makes the call idempotent.
        let preview: RasterDocument?
        do {
            preview = try doc.withLayerStyle(index, wanted)
        } catch {
            throw ToolError(message: error.localizedDescription)
        }
        guard let updated = preview else {
            return try jsonResult([
                "ok": true, "layer": index, "unchanged": true,
                "style": Self.layerStyleFields(doc, index) ?? NSNull(),
            ])
        }
        // The validated document IS the edit (same source document, same
        // main-thread call): the core's setter hands the previous style's
        // rendered planes to the new one and drains the old cache, so a
        // second call inside the group would commit a style with no planes
        // — a full re-render on the next composite — while this discarded
        // copy kept them.
        try performGroupedEdit(document, wanted == nil ? "Clear Layer Style" : "Layer Style") {
            _ in updated
        }
        return try jsonResult([
            "ok": true, "layer": index,
            "style": Self.layerStyleFields(document.doc, index) ?? NSNull(),
        ])
    }

    /// set_global_light — mirrors the Use Global Light angle/altitude edits
    /// in the Layer Style panes: the document's shared light, read by every
    /// effect with use_global_light on. Either argument may be omitted.
    func setGlobalLight(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        var values: [String: Double] = [:]
        for name in ["angle", "altitude"] where a[name] != nil {
            guard let value = doubleArg(a, name), value.isFinite else {
                throw ToolError(message: "\(name) must be a finite number of degrees")
            }
            values[name] = value
        }
        guard !values.isEmpty else {
            throw ToolError(
                message: "set_global_light needs angle (degrees; 0 = light from the right, "
                    + "90 = from the top) and/or altitude (0..90) — nothing to change")
        }
        let angle = values["angle"] ?? doc.globalLightAngle
        let altitude = values["altitude"] ?? doc.globalLightAltitude
        // The core sanitizes (altitude clamped, angle normalized) and refuses
        // a value equal to the current one — no phantom undo step.
        guard doc.withGlobalLight(angle: angle, altitude: altitude) != nil else {
            return try jsonResult([
                "ok": true, "unchanged": true, "global_light": Self.globalLightFields(doc),
            ])
        }
        try performGroupedEdit(document, "Global Light") {
            $0.withGlobalLight(angle: angle, altitude: altitude)
        }
        guard let updated = document.doc else { throw ToolError(message: "Document has no image") }
        return try jsonResult(["ok": true, "global_light": Self.globalLightFields(updated)])
    }

    /// The `style` argument as the JSON string the core takes: an object
    /// (re-serialized; the core canonicalizes key order), a JSON string as
    /// is, or nil for null / absent / empty — which clears.
    private static func styleArgument(_ raw: Any?) throws -> String? {
        switch raw {
        case nil, is NSNull:
            return nil
        case let object as [String: Any]:
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object)
            else { throw ToolError(message: "style must be a JSON object or null") }
            return String(decoding: data, as: UTF8.self)
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == "null" ? nil : text
        default:
            throw ToolError(
                message: "style must be a JSON object (the shape get_document reports) or "
                    + "null to clear")
        }
    }

    /// Layer `index`'s style as the canonical object (every key of every
    /// present effect) — what get_document reports and what set_layer_style
    /// takes back unchanged; nil for an unstyled layer.
    static func layerStyleFields(_ doc: RasterDocument?, _ index: Int) -> [String: Any]? {
        guard let json = doc?.layerStyle(index),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        else { return nil }
        return shortNumbers(object) as? [String: Any]
    }

    /// JSONSerialization writes a parsed double back with 17 significant
    /// digits (`0.9` → `0.90000000000000002`), which would misreport the
    /// core's 4-decimal values; a decimal number built from Swift's
    /// shortest round-trip spelling prints as the core wrote it. Integers
    /// (objCType "q") pass through untouched.
    private static func shortNumbers(_ value: Any) -> Any {
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            guard type == "d" || type == "f" else { return number }
            return NSDecimalNumber(string: "\(number.doubleValue)")
        }
        if let object = value as? [String: Any] {
            return object.mapValues(shortNumbers)
        }
        if let array = value as? [Any] {
            return array.map(shortNumbers)
        }
        return value
    }

    /// The document's global light, degrees. The core stores the light to
    /// four decimals (its canonical precision for every style number), so
    /// the Float-to-Double widening is rounded back to that and spelled
    /// through `shortNumbers` — `33.3333`, never `33.333300000000001` — and
    /// the reported value echoed into set_global_light is refused as
    /// unchanged, exactly like a style echo.
    static func globalLightFields(_ doc: RasterDocument) -> [String: Any] {
        let round: (Double) -> Double = { ($0 * 10000).rounded() / 10000 }
        let fields: [String: Any] = [
            "angle": round(doc.globalLightAngle), "altitude": round(doc.globalLightAltitude),
        ]
        return shortNumbers(fields) as? [String: Any] ?? fields
    }
}
