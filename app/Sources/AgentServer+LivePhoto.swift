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
        try performGroupedEdit(document, "Place Live Photo") {
            $0.addingLivePhotoLayer(above: below, payload, name: name)
        }
        // The new layer becomes the active one, as every other adding tool
        // leaves it.
        let index = min(below + 1, (document.doc?.layerCount ?? 1) - 1)
        document.activeLayerIndex = index
        return try jsonResult([
            "ok": true,
            "layer": index,
            "name": name,
            "live_photo": Self.livePhotoFields(payload),
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
                "live_photo": Self.livePhotoFields(payload),
            ])
        }
        try performGroupedEdit(document, "Select Live Photo Frame") {
            $0.settingLivePhotoFrame(index, seconds: seconds)
        }
        return try jsonResult([
            "ok": true, "layer": index, "live_photo": Self.livePhotoFields(updated),
        ])
    }

    /// The live_photo object every Live Photo reply (and get_document)
    /// reports: what the layer is showing and what else it could show.
    static func livePhotoFields(_ payload: LivePhotoPayload) -> [String: Any] {
        [
            "video": payload.video,
            "still": payload.still ?? NSNull(),
            "time": (payload.time * 1000).rounded() / 1000,
            "key_time": (payload.keyTime * 1000).rounded() / 1000,
            "duration": (payload.duration * 1000).rounded() / 1000,
            "showing_still": payload.showsStill,
            "width": payload.width,
            "height": payload.height,
        ]
    }
}
