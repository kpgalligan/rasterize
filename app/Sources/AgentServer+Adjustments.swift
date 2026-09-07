import AppKit

/// The agent side of the phase-5 adjustments: the destructive twin
/// `apply_filter` routes to, the one place a Color Lookup layer's table is
/// kept out of a reply, and the three Auto commands.
extension AgentServer {
    /// The destructive twin of the adjustment layer of the same name: the
    /// SAME core op (`rz_image_adjust_op`) the compositor runs, so the two
    /// can never drift. `params` is already validated — `applyFilter`
    /// validates once, where it can still throw a message naming the
    /// offending key — so this is non-throwing and can be called from the
    /// plane path's non-throwing closure.
    ///
    /// nil only when the core refuses the op outright, which after
    /// validation means an image it could not allocate.
    func adjustmentFilter(
        _ image: RasterImage, _ filter: String, _ params: [String: Any]
    ) -> RasterImage? {
        image.applyingAdjustment(op: filter, params: params)
    }

    /// The `params` object of a tool call ([:] when omitted), before any
    /// op-specific validation. `apply_filter` needs it a step earlier than
    /// `adjustmentParams` does — it has to validate before the plane/pixel
    /// branch, where it can still throw — so the read lives here rather
    /// than being duplicated inside the frozen file.
    func adjustmentParamsObject(_ a: [String: Any]) throws -> [String: Any] {
        guard let raw = a["params"] else { return [:] }
        guard let object = raw as? [String: Any] else {
            throw ToolError(message: "params must be a JSON object, e.g. {\"density\": 0.4}")
        }
        return object
    }

    /// The flat argument names each pre-phase-5 `apply_filter` filter reads,
    /// mirroring `AgentServer.filtered`'s arms one for one. A filter absent
    /// from this table is either an adjustment op (which takes `params`) or
    /// not a filter at all.
    static let flatFilterArguments: [String: [String]] = [
        "grayscale": [], "invert": [], "sepia": [], "edge_detect": [], "emboss": [],
        "blur": ["sigma"],
        "sharpen": ["amount"],
        "adjust": ["brightness", "contrast", "saturation"],
        "levels": ["black", "white", "gamma"],
        "hue_rotate": ["degrees"],
        "threshold": ["level"],
        "posterize": ["levels"],
        "pixelate": ["block"],
        "add_noise": ["amount", "seed"],
    ]

    /// `apply_filter`'s own arguments, as opposed to any filter's: what may
    /// legitimately sit beside `filter` whatever the filter is. Everything
    /// else at the top level belongs to ONE of the two argument styles, and
    /// is refused by whichever of the two does not read it.
    static let filterEnvelopeKeys: Set<String> = [
        "filter", "layer", "target", "params", "document_id",
    ]

    /// `"a", "b" and "c"` — the offending keys of a refusal, in the wording
    /// both directions of the params/flat mismatch use.
    private func quoted(_ keys: [String]) -> String {
        let names = keys.map { "\"\($0)\"" }
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The whole of `apply_filter`'s params story, so the frozen file holds
    /// one call: the VALIDATED params object when `filter` is one of the
    /// twelve adjustment ops, and nil for the older filters — which read
    /// their arguments flat.
    ///
    /// **Both directions of the mismatch are refused, and neither is
    /// ignored.** `params` is a top-level property of the one `apply_filter`
    /// schema whose `filter` enum lists `levels`, `posterize` and `adjust`
    /// beside the twelve ops that honour it, and three of those legacy names
    /// are themselves adjustment-layer ops — so passing `params` to a legacy
    /// filter is a likely mistake. The inverse is likelier still: `gamma`,
    /// `levels`, `black`, `white`, `degrees`, `level` and `saturation` are
    /// declared top-level properties of this same tool, so spelling an
    /// adjustment op's parameters flat looks exactly like spelling a legacy
    /// filter's. Either way, dropping what was passed silently reported
    /// `ok: true`, applied the filter's DEFAULTS — which for `photo_filter`
    /// meant warming an image the caller asked to cool — and registered an
    /// undo step for an edit nobody asked for. Both refusals are in-band and
    /// name the keys, so a model corrects itself in one turn.
    func adjustmentFilterParams(_ a: [String: Any], filter: String) throws -> [String: Any]? {
        if let op = AdjustmentSchema.op(forFilter: filter) {
            let stray = a.keys.filter { !Self.filterEnvelopeKeys.contains($0) }.sorted()
            if !stray.isEmpty {
                let shape = AdjustmentSchema.inputKeys(for: op).prefix(3)
                    .map { "\"\($0)\": …" }.joined(separator: ", ")
                throw ToolError(
                    message: "apply_filter: \"\(filter)\" takes its parameters inside a params "
                        + "object, not beside \"filter\" — {\"params\": {\(shape)}}. "
                        + quoted(stray) + " would have been ignored and \(filter)'s DEFAULTS "
                        + "applied instead. Nothing was applied.")
            }
            return try AdjustmentSchema.validate(adjustmentParamsObject(a), for: op)
        }
        // An unknown filter is not this function's refusal to make: the
        // dispatch below already fails and names it.
        guard let flat = Self.flatFilterArguments[filter], a["params"] != nil else { return nil }
        let takes = flat.isEmpty
            ? "takes no arguments"
            : "takes its arguments flat, beside \"filter\": " + flat.joined(separator: ", ")
        throw ToolError(
            message: "apply_filter: \"\(filter)\" \(takes) — not inside a params object, "
                + "which only the adjustment ops read. Nothing was applied.")
    }

    /// An adjustment layer's params as `get_document` reports them: every
    /// key intact except a Color Lookup's `table`, which is up to ~575 KB of
    /// base64 and would swamp the reply (and every later one, since a model
    /// re-reads the document). What is left — `kind`, `size`, `source_size`,
    /// the domain, `strength`, `title` — is everything an agent needs to
    /// reason about the layer, and `edit_adjustment_layer` either keeps the
    /// stored LUT (omit the table keys, or echo this placeholder back) or
    /// replaces the whole thing from a `file` path — which is what the
    /// placeholder text says, since it is the only instruction an agent
    /// reading a document reply gets.
    ///
    /// Used by `get_document` AND by `edit_adjustment_layer`'s own reply, so
    /// the two read paths agree and neither can put ~575 KB of base64 into
    /// a conversation.
    func elidedAdjustmentParams(_ payload: AdjustmentLayerPayload) -> [String: Any] {
        var params = payload.params
        guard payload.op == AdjustmentLayerOp.colorLookup.rawValue,
              params["table"] is String
        else { return params }
        let size = (params["size"] as? NSNumber)?.intValue ?? 0
        let nodes = payload.string("kind", default: "3d") == "3d" ? size * size * size : size
        params["table"] =
            "<\(nodes) entries elided — omit it (or pass it back unchanged) to keep this LUT, "
            + "or pass file with a .cube path to replace it>"
        return params
    }

    /// The keys that describe a `color_lookup` layer's stored LUT, as
    /// opposed to how it is APPLIED (`strength`, the only key left out).
    /// `title` is in the set because it travels with the table everywhere
    /// else too: loading a `file` replaces it along with the numbers
    /// (`AdjustmentSchema.validate`), and it names the .cube, not the
    /// layer. Exactly what `file` replaces wholesale, and exactly what the
    /// merge below carries forward.
    static let lutTableKeys = [
        "kind", "size", "table", "source_size", "domain_min", "domain_max", "title",
    ]

    /// `edit_adjustment_layer`'s ONE merge, on the ONE op that needs it.
    ///
    /// `params` is otherwise a wholesale replacement, deliberately. But a
    /// `color_lookup` layer's `table` is up to ~575 KB of base64, so
    /// `get_document` hands out a placeholder instead of it, and the layer
    /// stores no .cube path — which between them made the obvious flow
    /// ("read the params, change one key, write them back") impossible:
    /// omitting `table` was refused for want of a `kind`, and echoing the
    /// placeholder back was refused as invalid base64. An agent that did
    /// not itself load the LUT — a reopened .rz, a LUT the user picked in
    /// the sheet, a pruned conversation — could never touch `strength`
    /// again, while the UI's own sheet edited the layer fine.
    ///
    /// So: when the layer already IS a `color_lookup` and the call names no
    /// replacement table — no `file`, and either no `table` or just the
    /// elision placeholder (which can never be confused with base64, having
    /// angle brackets) — the stored table and the keys describing it are
    /// carried forward. Everything else still comes from the call.
    ///
    /// Takes and returns the whole argument dictionary so the frozen file's
    /// call site stays one line.
    func mergingStoredLut(
        _ a: [String: Any], op: AdjustmentLayerOp, current: AdjustmentLayerPayload?
    ) -> [String: Any] {
        guard op == .colorLookup,
              let current = current,
              current.op == AdjustmentLayerOp.colorLookup.rawValue,
              var params = a["params"] as? [String: Any],
              params["file"] == nil
        else { return a }
        if let table = params["table"] as? String, table.hasPrefix("<"), table.hasSuffix(">") {
            params.removeValue(forKey: "table")
        }
        for key in Self.lutTableKeys where params[key] == nil {
            if let value = current.params[key] { params[key] = value }
        }
        var merged = a
        merged["params"] = params
        return merged
    }

    // MARK: - Auto Tone / Auto Contrast / Auto Color

    /// auto_tone: the agent mirror of Image ▸ Auto Tone (⇧⌘L).
    func autoTone(_ a: [String: Any]) throws -> String {
        try autoLevels(a, mode: RZ_AUTO_TONE, action: "Auto Tone")
    }

    /// auto_contrast: the agent mirror of Image ▸ Auto Contrast (⌥⇧⌘L).
    func autoContrast(_ a: [String: Any]) throws -> String {
        try autoLevels(a, mode: RZ_AUTO_CONTRAST, action: "Auto Contrast")
    }

    /// auto_color: the agent mirror of Image ▸ Auto Color (⇧⌘B).
    func autoColor(_ a: [String: Any]) throws -> String {
        try autoLevels(a, mode: RZ_AUTO_COLOR, action: "Auto Color")
    }

    /// The three share one body: derive Levels parameters from the layer's
    /// own histogram (the core's counting rule, so a transparent surround
    /// never pins the black point at 0), then apply the SAME levels math the
    /// Levels dialog and the levels adjustment run. One undo step; an image
    /// already at full range writes nothing and reports `changed: false`.
    ///
    /// A GROUP is refused, by `paintLayerIndex` and in its words: a group has
    /// no pixels of its own to stretch, only a projection of the layers
    /// inside it, and writing that projection back would flatten the group.
    /// The refusal names the group's children so a model can auto-level them
    /// one at a time — or it can add a levels ADJUSTMENT LAYER inside the
    /// group, which recolors everything below it there without touching a
    /// single stored pixel.
    private func autoLevels(
        _ a: [String: Any], mode: RzAutoMode, action: String
    ) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        try rejectAdjustmentPixelEdit(document, index)
        let clip = doubleArg(a, "clip") ?? 0.001
        guard clip >= 0, clip <= 0.1 else {
            throw ToolError(
                message: "clip must be between 0 and 0.1 — the share of pixels dropped at "
                    + "each end (default 0.001 = 0.1 %, Photoshop's own) — got \(clip)")
        }
        guard let doc = document.doc, let layer = doc.layerImage(index) else {
            throw ToolError(message: "Layer \(index) has no pixels")
        }
        guard let derived = layer.autoLevels(mask: nil, mode: mode, clip: clip) else {
            return try jsonResult([
                "ok": true, "layer": index, "changed": false,
                "note": "\(action) would change nothing: the layer's histogram already "
                    + "spans the full range (and, for auto_color, its midtones are "
                    + "already neutral). No undo step was registered.",
            ])
        }
        let rasterized = try performPixelEdit(document, action, pixelLayer: index) { doc in
            guard let layer = doc.layerImage(index),
                  let corrected = layer.levelsChannels(
                    black: derived.black, white: derived.white, gamma: derived.gamma)
            else { return nil }
            return doc.withLayerPixels(index, corrected)
        }
        return try pixelEditResult(
            [
                "ok": true, "layer": index, "changed": true, "clip": clip,
                "black": derived.black, "white": derived.white, "gamma": derived.gamma,
            ],
            layer: index, rasterized: rasterized)
    }
}
