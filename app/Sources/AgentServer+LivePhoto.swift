import AppKit

/// The agent's half of the Live Photo feature: the MCP mirrors of
/// Layer > Place Live Photo… and Layer > Select Live Photo Frame…
/// (EditorViewController+LivePhoto.swift). Catalog entries live in
/// AgentCatalog.swift and the dispatch entries in AgentServer.handlers —
/// start() asserts the two agree.
extension AgentServer {
    /// add_live_photo_layer — mirrors Layer > Place Live Photo…: the key
    /// frame of the Live Photo at `path` becomes a new layer above the
    /// active one, carrying the description set_live_photo_frame re-renders
    /// from. `time` optionally picks a moment other than the key frame in
    /// the same step.
    func addLivePhotoLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let path = try requiredString(a, "path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError(message: "No file at \(url.path)")
        }
        guard let source = LivePhoto.locate(url), var payload = LivePhoto.inspect(source) else {
            throw ToolError(
                message: "\(url.lastPathComponent) is not half of a Live Photo. A Live Photo is "
                    + "a photo and a short video sharing one name in one folder "
                    + "(IMG_0001.HEIC and IMG_0001.MOV); pass either one.")
        }
        if let seconds = doubleArg(a, "time") {
            payload = payload.settingTime(seconds)
        }
        let below = intArg(a, "layer") ?? document.activeLayerIndex
        guard below >= 0, below < doc.layerCount else {
            throw ToolError(message: "Layer \(below) is out of range (0..\(doc.layerCount - 1))")
        }
        let name = stringArg(a, "name") ?? LivePhoto.layerName(for: source)
        // Where the new layer will land, from the stack BEFORE the edit:
        // above a GROUP a new entry goes above the whole subtree, so
        // `below + 1` would name the group's topmost CHILD.
        let landing = doc.insertionIndex(above: below)
        try performGroupedEdit(document, "Place Live Photo") {
            $0.addingLivePhotoLayer(above: below, payload, name: name)
        }
        // The new layer becomes the active one, as every other adding tool
        // leaves it.
        let index = min(landing, (document.doc?.layerCount ?? 1) - 1)
        document.activeLayerIndex = index
        // Reported from the committed document, so the reply's transform
        // and origin are what get_document will say — the identity at the
        // still's top-left for a freshly placed layer.
        let landed = document.doc?.livePhotoPayload(index) ?? payload
        return try jsonResult([
            "ok": true,
            "layer": index,
            "name": name,
            "live_photo": Self.livePhotoFields(
                landed, anchor: document.doc?.describedAnchor(index)),
        ])
    }

    /// set_live_photo_frame — mirrors the frame picker: re-renders a live
    /// photo layer at another moment of its clip, as one undo step. The
    /// requested time is clamped into the clip and snaps to the key frame
    /// when it lands within a frame of it, so the reply says which moment
    /// actually landed.
    func setLivePhotoFrame(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let index = intArg(a, "layer") ?? document.activeLayerIndex
        guard index >= 0, index < doc.layerCount else {
            throw ToolError(message: "Layer \(index) is out of range (0..\(doc.layerCount - 1))")
        }
        guard let payload = doc.livePhotoPayload(index) else {
            throw ToolError(
                message: "Layer \(index) is not a Live Photo layer — only a layer with a "
                    + "live_photo description (see get_document) has frames to choose from.")
        }
        guard payload.sourceExists else {
            throw ToolError(
                message: "The Live Photo's video (\(payload.video)) is no longer there, so "
                    + "another frame cannot be rendered. The layer's pixels are unaffected.")
        }
        guard let seconds = doubleArg(a, "time"), seconds.isFinite else {
            throw ToolError(
                message: "set_live_photo_frame requires time in seconds "
                    + "(0..\(String(format: "%.2f", payload.duration)))")
        }
        let updated = payload.settingTime(seconds)
        guard updated != payload else {
            // Re-rendering the moment already showing would be an identical
            // copy: a phantom undo step, and a dirtied file for nothing.
            return try jsonResult([
                "ok": true, "layer": index, "unchanged": true,
                "live_photo": Self.livePhotoFields(payload, anchor: doc.describedAnchor(index)),
            ])
        }
        // The frame re-renders through the layer's own transform at its own
        // anchor (settingLivePhotoFrame), so name, position, opacity, blend
        // mode, mask, style and transform all survive — the reply reads the
        // description back from the committed document rather than echoing
        // `updated`, so a transformed layer reports the transform that
        // actually landed.
        // A new frame REWRITES the layer's pixels, so it answers to the same
        // locks every other pixel tool does; without it a lock refusal was
        // reported as the generic "check the parameters".
        try rejectLockedEdit(document, index, RZ_EDIT_PIXELS)
        // No `rejectLockedRerender` here, unlike text and shape: a new FRAME
        // renders through the same map at the same size, so a TRANSPARENCY
        // lock never refuses one, and attributing an unrelated refusal (a
        // missing video file) to it would name the wrong cause.
        try performGroupedEdit(document, "Select Live Photo Frame") {
            $0.settingLivePhotoFrame(index, seconds: seconds)
        }
        let landed = document.doc?.livePhotoPayload(index) ?? updated
        return try jsonResult([
            "ok": true, "layer": index,
            "live_photo": Self.livePhotoFields(
                landed, anchor: document.doc?.describedAnchor(index)),
        ])
    }

    /// The live_photo object every Live Photo reply (and get_document)
    /// reports: what the layer is showing and what else it could show, its
    /// `transform` row-major (`LinearMap.array`), and `origin` — the exact
    /// canvas position of the still's top-left (fractional after a
    /// transform) — when the anchor is known.
    static func livePhotoFields(_ payload: LivePhotoPayload, anchor: CGPoint?) -> [String: Any] {
        var fields: [String: Any] = [
            "video": payload.video,
            "still": payload.still ?? NSNull(),
            "time": (payload.time * 1000).rounded() / 1000,
            "key_time": (payload.keyTime * 1000).rounded() / 1000,
            "duration": (payload.duration * 1000).rounded() / 1000,
            "showing_still": payload.showsStill,
            "width": payload.width,
            "height": payload.height,
            "transform": payload.transform.array,
        ]
        if let anchor = anchor {
            fields["origin"] = ["x": Double(anchor.x), "y": Double(anchor.y)]
        }
        return fields
    }
}
