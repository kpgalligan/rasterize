import AppKit

/// Hosts the core's embedded MCP server (streamable HTTP on 127.0.0.1)
/// and executes its tool calls against the open documents. The Rust side
/// owns the protocol; this class owns the tool catalog and the dispatch,
/// which runs on the main thread so every edit flows through the same
/// applyEdit path as the UI — undoable, dirtying, and live in the window.
///
/// Point any MCP client at http://127.0.0.1:<port>/mcp — e.g.
///   goose session --with-streamable-http-extension "http://127.0.0.1:4816/mcp"
///
/// The endpoint is unauthenticated: any local process may connect while
/// it runs. It is off by default (Tools > Allow Agent Connections).
final class AgentServer {
    static let shared = AgentServer()
    static let enabledDefaultsKey = "AgentServerEnabled"
    static let defaultPort: UInt16 = 4816

    private(set) var port: UInt16 = 0
    var isRunning: Bool { port != 0 }

    private var documentIDs: [ObjectIdentifier: Int] = [:]
    private var nextDocumentID = 1

    private struct ToolError: Error {
        let message: String
    }

    // MARK: - Lifecycle

    /// Starts on RZ_AGENT_PORT or the default port, falling back to an
    /// ephemeral port when that is taken. Throws with a message on failure.
    func start() throws {
        guard !isRunning else { return }
        let preferred =
            ProcessInfo.processInfo.environment["RZ_AGENT_PORT"]
            .flatMap(UInt16.init) ?? Self.defaultPort
        let catalog = try catalogJSON()
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0"
        let context = Unmanaged.passUnretained(self).toOpaque()

        var bound: UInt16 = 0
        var lastError = "could not start the agent server"
        for candidate in [preferred, 0] where bound == 0 {
            var err: UnsafeMutablePointer<CChar>? = nil
            bound = rz_agent_server_start(
                candidate, "rasterize", version, catalog, agentToolTrampoline, context, &err)
            if let err = err {
                lastError = String(cString: err)
                rz_string_free(err)
            }
        }
        guard bound != 0 else {
            throw ToolFailure(message: lastError)
        }
        port = bound
        NSLog("Rasterize agent server listening on http://127.0.0.1:%d/mcp", Int(bound))
    }

    func stop() {
        guard isRunning else { return }
        rz_agent_server_stop()
        port = 0
    }

    struct ToolFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Dispatch (main thread)

    /// Executes one tool call and returns CallToolResult JSON. Errors are
    /// in-band (isError: true) so the model can read and correct them.
    func execute(tool: String, argumentsJSON: String) -> String {
        assert(Thread.isMainThread)
        let arguments =
            (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)))
            as? [String: Any] ?? [:]
        do {
            return try dispatch(tool, arguments)
        } catch let error as ToolError {
            return errorResult(error.message)
        } catch {
            return errorResult(error.localizedDescription)
        }
    }

    private func dispatch(_ tool: String, _ a: [String: Any]) throws -> String {
        switch tool {
        case "list_documents": return try listDocuments()
        case "open_document": return try openDocument(a)
        case "get_document": return try getDocument(a)
        case "render": return try render(a)
        case "set_active_layer": return try setActiveLayer(a)
        case "new_layer": return try newLayer(a)
        case "duplicate_layer": return try layerEdit(a, "Duplicate Layer") { $0.duplicatingLayer($1) }
        case "delete_layer": return try layerEdit(a, "Delete Layer") { $0.removingLayer($1) }
        case "merge_down": return try mergeDown(a)
        case "flatten_image": return try docEdit(a, "Flatten Image") { $0.flattening() }
        case "reorder_layer": return try reorderLayer(a)
        case "set_layer_properties": return try setLayerProperties(a)
        case "transform_layer": return try transformLayer(a)
        case "add_layer_mask": return try addLayerMask(a)
        case "remove_layer_mask": return try removeLayerMask(a)
        case "set_layer_mask_enabled": return try setLayerMaskEnabled(a)
        case "apply_filter": return try applyFilter(a)
        case "brush_stroke": return try paintStroke(a, erase: false)
        case "eraser_stroke": return try paintStroke(a, erase: true)
        case "add_text": return try addText(a)
        case "add_text_layer": return try addTextLayer(a)
        case "edit_text_layer": return try editTextLayer(a)
        case "select_rect": return try selectShape(a) { rect in .rect(rect) }
        case "select_ellipse": return try selectShape(a) { rect in .ellipse(rect) }
        case "select_polygon": return try selectPolygon(a)
        case "select_magic_wand": return try selectMagicWand(a)
        case "deselect": return try deselect(a)
        case "modify_selection": return try modifySelection(a)
        case "fill": return try fill(a)
        case "gradient": return try gradient(a)
        case "clear_selection": return try clearSelection(a)
        case "rotate": return try rotate(a)
        case "flip": return try flip(a)
        case "crop": return try crop(a)
        case "image_size": return try imageSize(a)
        case "canvas_size": return try canvasSize(a)
        case "undo": return try undoRedo(a, redo: false)
        case "redo": return try undoRedo(a, redo: true)
        case "save_copy": return try saveCopy(a)
        default: throw ToolError(message: "Unknown tool: \(tool)")
        }
    }

    // MARK: - Documents

    private func openDocuments() -> [ImageDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? ImageDocument }
    }

    private func id(for document: ImageDocument) -> Int {
        let key = ObjectIdentifier(document)
        if let existing = documentIDs[key] { return existing }
        documentIDs[key] = nextDocumentID
        nextDocumentID += 1
        return nextDocumentID - 1
    }

    /// The stable tool-facing id of a document (the assistant panel pins
    /// its session to one document through this).
    func documentID(for document: ImageDocument) -> Int {
        id(for: document)
    }

    /// The document a call targets: document_id when given, else the
    /// current (main window's) document, else the only open one.
    private func target(_ a: [String: Any]) throws -> ImageDocument {
        let documents = openDocuments()
        if let wanted = intArg(a, "document_id") {
            guard let match = documents.first(where: { id(for: $0) == wanted }) else {
                throw ToolError(message: "No open document has id \(wanted). Call list_documents.")
            }
            return match
        }
        if let current = NSDocumentController.shared.currentDocument as? ImageDocument {
            return current
        }
        guard let first = documents.first else {
            throw ToolError(message: "No documents are open. Call open_document first.")
        }
        return first
    }

    private func summary(_ document: ImageDocument) -> [String: Any] {
        [
            "id": id(for: document),
            "title": document.displayName ?? "Untitled",
            "path": document.fileURL?.path ?? NSNull(),
            "width": document.doc?.width ?? 0,
            "height": document.doc?.height ?? 0,
            "layer_count": document.doc?.layerCount ?? 0,
            "active_layer": document.activeLayerIndex,
            "unsaved_changes": document.isDocumentEdited,
        ]
    }

    private func listDocuments() throws -> String {
        let list = openDocuments().map(summary)
        return try jsonResult(["documents": list, "note": "layer index 0 is the bottom layer"])
    }

    private func openDocument(_ a: [String: Any]) throws -> String {
        let path = try requiredString(a, "path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError(message: "No file at \(url.path)")
        }
        let controller = NSDocumentController.shared
        if let existing = controller.document(for: url) as? ImageDocument {
            return try jsonResult(["already_open": true, "document": summary(existing)])
        }
        let type = try controller.typeForContents(of: url)
        guard let document = try controller.makeDocument(withContentsOf: url, ofType: type)
            as? ImageDocument
        else {
            throw ToolError(message: "\(url.lastPathComponent) did not open as an image document")
        }
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        controller.noteNewRecentDocumentURL(url)
        return try jsonResult(["document": summary(document)])
    }

    private func getDocument(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let layers: [[String: Any]] = (0..<doc.layerCount).compactMap { index -> [String: Any]? in
            guard let info = doc.layerInfo(index) else { return nil }
            var layer: [String: Any] = [
                "index": index,
                "name": info.name,
                "width": info.width,
                "height": info.height,
                "offset_x": info.offsetX,
                "offset_y": info.offsetY,
                "opacity": (info.opacity * 100).rounded() / 100,
                "blend_mode": RzBlendMode.displayName(for: info.blendMode),
                "visible": info.visible,
                "has_mask": doc.layerHasMask(index),
                "mask_enabled": doc.layerMaskEnabled(index),
            ]
            // A TEXT LAYER also carries the description its pixels were
            // rendered from; only those layers can be re-rendered with
            // edit_text_layer, and the key's absence says "plain raster".
            if let payload = doc.textPayload(index) {
                layer["text"] = [
                    "string": payload.string,
                    "font": payload.font,
                    "size": payload.size,
                    "color": payload.color,
                ]
            }
            return layer
        }
        var result = summary(document)
        result["layers"] = layers
        if let selection = editor(document)?.agentSelection {
            let b = selection.bounds
            let kind: String
            switch selection.shape {
            case .rect: kind = "rect"
            case .ellipse: kind = "ellipse"
            case .polygon: kind = "polygon"
            case .mask: kind = "mask"
            }
            result["selection"] = [
                "kind": kind,
                "x": Int(b.minX), "y": Int(b.minY),
                "width": Int(b.width), "height": Int(b.height),
            ]
        }
        result["note"] = "index 0 is the bottom layer; offsets are from the canvas top-left, y down"
        return try jsonResult(result)
    }

    // MARK: - Rendering

    private func render(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let source: RasterImage?
        var what: String
        if let layer = intArg(a, "layer") {
            guard layer >= 0, layer < doc.layerCount else {
                throw ToolError(message: "Layer \(layer) is out of range (0..\(doc.layerCount - 1))")
            }
            source = doc.layerImage(layer)
            what = "layer \(layer) (\(doc.layerInfo(layer)?.name ?? ""))"
        } else {
            source = document.projection ?? doc.flattened()
            what = "flattened canvas"
        }
        guard var image = source else { throw ToolError(message: "Could not render") }

        let maxSide = min(max(intArg(a, "max_side") ?? 1024, 64), 4096)
        let fullWidth = image.width
        let fullHeight = image.height
        if max(fullWidth, fullHeight) > maxSide {
            let scale = Double(maxSide) / Double(max(fullWidth, fullHeight))
            let w = max(Int((Double(fullWidth) * scale).rounded()), 1)
            let h = max(Int((Double(fullHeight) * scale).rounded()), 1)
            guard let scaled = image.resized(w: w, h: h, filter: RZ_FILTER_BILINEAR) else {
                throw ToolError(message: "Could not scale the render")
            }
            image = scaled
        }
        guard let cgImage = image.makeCGImage(),
            let png = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .png, properties: [:])
        else {
            throw ToolError(message: "PNG encoding failed")
        }
        what += " of \(document.displayName ?? "Untitled")"
        let text =
            "\(what): full size \(fullWidth)×\(fullHeight) px, rendered at "
            + "\(image.width)×\(image.height) px"
        return try callResult(
            content: [
                ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                ["type": "text", "text": text],
            ], isError: false)
    }

    // MARK: - Layer operations

    private func layerIndex(_ a: [String: Any], _ document: ImageDocument) throws -> Int {
        let index = intArg(a, "index") ?? document.activeLayerIndex
        let count = document.doc?.layerCount ?? 0
        guard index >= 0, index < count else {
            throw ToolError(message: "Layer \(index) is out of range (0..\(count - 1))")
        }
        return index
    }

    /// Runs `transform` and registers it through applyEdit inside an
    /// explicit undo group, then force-closes any implicit event group
    /// NSUndoManager wrapped around it. Off the event path (these calls
    /// arrive via dispatch-to-main, not a real UI event) the implicit
    /// group would otherwise stay open across tool calls, merging every
    /// agent edit into one undo step. The transform runs first so a
    /// failed edit never opens a group.
    private func performEdit(
        _ document: ImageDocument, _ actionName: String,
        _ transform: (RasterDocument) -> RasterDocument?
    ) throws {
        guard let current = document.doc, let updated = transform(current) else {
            throw ToolError(message: "\(actionName) failed — check the parameters")
        }
        let manager = document.undoManager
        manager?.beginUndoGrouping()
        document.applyEdit(actionName) { _ in updated }
        manager?.endUndoGrouping()
        while let manager = manager, manager.groupingLevel > 0 {
            manager.endUndoGrouping()
        }
    }

    /// performEdit for an edit that REWRITES A LAYER'S PIXELS — a brush or
    /// eraser stroke on the layer itself, a fill, a gradient, add_text, a
    /// filter or an adjustment. Those pixels stop being the rendering of a
    /// text layer's description, so the description is DROPPED inside the
    /// same edit (one undo step, one handle), and the caller tells the model.
    ///
    /// The UI asks the user first (ImageDocument.applyRasterizingEdit), but
    /// the agent must never: a modal alert on this dispatched-to-main path
    /// would block the main thread — and with it the MCP connection — until
    /// somebody clicked it. Rasterizing silently and REPORTING it is the
    /// recovery-oriented equivalent: undo restores the text layer.
    ///
    /// `pixelLayer` is the layer whose own pixels the edit rewrites, or nil
    /// when it writes somewhere else (a layer MASK), which leaves a text
    /// description valid. Returns true when a description was dropped.
    @discardableResult
    private func performPixelEdit(
        _ document: ImageDocument, _ actionName: String, pixelLayer: Int?,
        _ transform: (RasterDocument) -> RasterDocument?
    ) throws -> Bool {
        let rasterizesText =
            pixelLayer.map { document.doc?.textPayload($0) != nil } ?? false
        try performEdit(document, actionName) { doc in
            guard let updated = transform(doc) else { return nil }
            guard rasterizesText, let layer = pixelLayer else { return updated }
            return updated.withLayerMeta(layer, nil) ?? updated
        }
        return rasterizesText
    }

    /// A pixel-edit result, with the rasterization report appended when the
    /// edit dropped a text layer's description.
    private func pixelEditResult(
        _ fields: [String: Any], layer: Int, rasterizedText: Bool
    ) throws -> String {
        var result = fields
        if rasterizedText {
            result["rasterized_text"] = true
            result["note"] =
                "This edit painted over layer \(layer)'s pixels, so the layer is no longer "
                + "editable as text: the string, font, size and color it was rendered from "
                + "were dropped and edit_text_layer no longer works on it. The pixels are "
                + "intact; undo restores the text layer."
        }
        return try jsonResult(result)
    }

    private func docEdit(
        _ a: [String: Any], _ actionName: String,
        _ transform: @escaping (RasterDocument) -> RasterDocument?
    ) throws -> String {
        let document = try target(a)
        try performEdit(document, actionName, transform)
        return try jsonResult(["ok": true, "document": summary(document)])
    }

    private func layerEdit(
        _ a: [String: Any], _ actionName: String,
        _ transform: @escaping (RasterDocument, Int) -> RasterDocument?
    ) throws -> String {
        let document = try target(a)
        let index = try layerIndex(a, document)
        try performEdit(document, actionName) { transform($0, index) }
        return try jsonResult(["ok": true, "document": summary(document)])
    }

    private func setActiveLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let index = intArg(a, "index") else {
            throw ToolError(message: "set_active_layer requires index")
        }
        let count = document.doc?.layerCount ?? 0
        guard index >= 0, index < count else {
            throw ToolError(message: "Layer \(index) is out of range (0..\(count - 1))")
        }
        document.activeLayerIndex = index
        NotificationCenter.default.post(
            name: .imageDocumentImageDidChange, object: document, userInfo: ["isLive": false])
        return try jsonResult(["ok": true, "active_layer": index])
    }

    private func newLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let index = document.activeLayerIndex
        let name = stringArg(a, "name") ?? "Layer \(doc.layerCount + 1)"
        try performEdit(document, "New Layer") { $0.addingLayer(above: index, name: name) }
        document.activeLayerIndex = min(index + 1, (document.doc?.layerCount ?? 1) - 1)
        return try jsonResult(
            ["ok": true, "new_layer_index": document.activeLayerIndex, "name": name])
    }

    private func mergeDown(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try layerIndex(a, document)
        guard index >= 1 else {
            throw ToolError(message: "The bottom layer has nothing below it to merge into")
        }
        try performEdit(document, "Merge Down") { $0.mergingDown(index) }
        document.activeLayerIndex = index - 1
        return try jsonResult(["ok": true, "document": summary(document)])
    }

    private func reorderLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let from = intArg(a, "from"), let to = intArg(a, "to") else {
            throw ToolError(message: "reorder_layer requires from and to")
        }
        try performEdit(document, "Reorder Layer") { $0.movingLayer(from: from, to: to) }
        return try jsonResult(["ok": true, "document": summary(document)])
    }

    private func setLayerProperties(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try layerIndex(a, document)
        var blendMode: RzBlendMode?
        if let name = stringArg(a, "blend_mode") {
            blendMode = RzBlendMode.allBlendModes.first {
                $0.1.caseInsensitiveCompare(name) == .orderedSame
            }?.0
            guard blendMode != nil else {
                let names = RzBlendMode.allBlendModes.map { $0.1 }.joined(separator: ", ")
                throw ToolError(message: "Unknown blend mode \"\(name)\". One of: \(names)")
            }
        }
        let name = stringArg(a, "name")
        let opacity = doubleArg(a, "opacity")
        let visible = boolArg(a, "visible")
        let offsetX = intArg(a, "offset_x")
        let offsetY = intArg(a, "offset_y")
        guard name != nil || opacity != nil || visible != nil || blendMode != nil
            || offsetX != nil || offsetY != nil
        else {
            throw ToolError(message: "set_layer_properties: nothing to change")
        }
        try performEdit(document, "Layer Properties") { doc in
            var updated: RasterDocument? = doc
            if let name = name { updated = updated?.withLayerName(index, name) }
            if let opacity = opacity {
                updated = updated?.withLayerOpacity(index, min(max(opacity, 0), 1))
            }
            if let mode = blendMode { updated = updated?.withLayerBlendMode(index, mode) }
            if let visible = visible { updated = updated?.withLayerVisible(index, visible) }
            if offsetX != nil || offsetY != nil {
                let info = doc.layerInfo(index)
                updated = updated?.withLayerOffset(
                    index, offsetX ?? info?.offsetX ?? 0, offsetY ?? info?.offsetY ?? 0)
            }
            return updated
        }
        return try jsonResult(["ok": true, "document": summary(document)])
    }

    // MARK: - Layer masks

    /// The mask-owning layer a call targets, verified to actually have a
    /// mask so the failure names the fix instead of a generic edit error.
    private func maskedLayerIndex(
        _ a: [String: Any], _ document: ImageDocument, _ what: String
    ) throws -> Int {
        let index = try paintLayerIndex(a, document)
        guard document.doc?.layerHasMask(index) == true else {
            throw ToolError(
                message: "Layer \(index) has no mask to \(what). Add one with add_layer_mask.")
        }
        return index
    }

    private func addLayerMask(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        let kindName = stringArg(a, "kind") ?? "reveal_all"
        let kind: RzMaskKind
        var selection: [UInt8]? = nil
        switch kindName {
        case "reveal_all": kind = RZ_MASK_REVEAL_ALL
        case "hide_all": kind = RZ_MASK_HIDE_ALL
        case "from_selection":
            // The window's live selection — the same one the marquee shows;
            // the core crops the canvas-sized coverage to the layer's rect.
            guard let mask = selectionMask(document) else {
                throw ToolError(
                    message: "kind \"from_selection\" needs an active selection, and there is "
                        + "none. Make one with a select_* tool first, or use kind "
                        + "\"reveal_all\" / \"hide_all\".")
            }
            kind = RZ_MASK_FROM_SELECTION
            selection = mask
        case let other:
            throw ToolError(
                message: "kind must be reveal_all, hide_all, or from_selection (got \"\(other)\")")
        }
        try performEdit(document, "Add Layer Mask") {
            $0.addingLayerMask(index, kind: kind, selection: selection)
        }
        return try jsonResult(["ok": true, "layer": index, "kind": kindName, "mask_enabled": true])
    }

    private func removeLayerMask(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let apply = boolArg(a, "apply") ?? false
        let index = try maskedLayerIndex(a, document, apply ? "apply" : "remove")
        try performEdit(document, apply ? "Apply Layer Mask" : "Delete Layer Mask") {
            $0.removingLayerMask(index, apply: apply)
        }
        return try jsonResult(["ok": true, "layer": index, "applied": apply])
    }

    private func setLayerMaskEnabled(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let enabled = boolArg(a, "enabled") else {
            throw ToolError(message: "set_layer_mask_enabled requires enabled (true or false)")
        }
        let index = try maskedLayerIndex(a, document, enabled ? "enable" : "disable")
        try performEdit(document, enabled ? "Enable Layer Mask" : "Disable Layer Mask") {
            $0.withLayerMaskEnabled(index, enabled)
        }
        return try jsonResult(["ok": true, "layer": index, "mask_enabled": enabled])
    }

    // MARK: - Layer transform

    /// transform_layer's samplers, mapped onto the resize filters the Free
    /// Transform options bar offers ("bicubic" IS Catmull-Rom). image_size's
    /// spellings are accepted too, so one vocabulary covers both tools; the
    /// canonical name is what the result echoes back.
    private static let transformSamplers: [String: (name: String, filter: RzResizeFilter)] = [
        "nearest": ("nearest", RZ_FILTER_NEAREST),
        "bilinear": ("bilinear", RZ_FILTER_BILINEAR),
        "bicubic": ("bicubic", RZ_FILTER_CATMULL_ROM),
        "catmull-rom": ("bicubic", RZ_FILTER_CATMULL_ROM),
        "lanczos": ("lanczos", RZ_FILTER_LANCZOS3),
        "lanczos3": ("lanczos", RZ_FILTER_LANCZOS3),
    ]

    /// The core's ceiling on one layer's pixels (doc.rs MAX_PIXELS), mirrored
    /// so an oversized request is refused with a message that names the cap
    /// instead of a bare NULL from the core.
    private static let maxLayerPixels = 100_000_000.0

    /// A finite number argument; nil when the caller omitted it.
    private func finiteArg(_ a: [String: Any], _ key: String) throws -> Double? {
        guard let value = doubleArg(a, key) else { return nil }
        guard value.isFinite else {
            throw ToolError(message: "\(key) must be a finite number")
        }
        return value
    }

    /// A scale multiplier: finite, non-zero (zero is a singular matrix the
    /// core refuses) and clamped to the same magnitudes the Free Transform
    /// fields allow, so agent and UI accept exactly the same range.
    private func scaleArg(_ a: [String: Any], _ key: String) throws -> CGFloat? {
        guard let value = try finiteArg(a, key) else { return nil }
        guard value != 0 else {
            throw ToolError(
                message: "\(key) must not be 0 — a zero scale collapses the layer to nothing "
                    + "(a singular matrix the core refuses). 1 keeps the size, 0.5 halves it, "
                    + "-1 mirrors it.")
        }
        return LayerTransform.clampScale(CGFloat(value))
    }

    /// Two decimals, for the parameters the result echoes back — except when
    /// that would round a nonzero value away to 0, which would contradict this
    /// same tool's "a scale of 0 is refused" and misreport a scale clamped to
    /// the 0.001 floor. Anything smaller than half a hundredth keeps two
    /// significant digits instead, so the echo stays tidy but never claims a
    /// value the call would have rejected.
    private static func transformNumber(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return 0 }
        let rounded = (value * 100).rounded() / 100
        if rounded != 0 { return rounded }
        let unit = pow(10.0, 1 - (log10(abs(value))).rounded(.down))
        let significant = (value * unit).rounded() / unit
        return significant.isFinite && significant != 0 ? significant : value
    }

    /// Rotates / scales / moves ONE layer in a single resample. The named
    /// parameters are compiled into a LayerTransform and its matrix is what
    /// goes to the core — the very composition the interactive Free Transform
    /// session commits, so identical parameters give identical pixels.
    private func transformLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        guard let doc = document.doc, let info = doc.layerInfo(index) else {
            throw ToolError(message: "Layer \(index) could not be read")
        }
        guard info.width > 0, info.height > 0 else {
            throw ToolError(
                message: "Layer \(index) (\"\(info.name)\") has no pixels to transform.")
        }
        // The layer's rect in CANVAS space — what the matrix maps.
        let rect = CGRect(
            x: CGFloat(info.offsetX), y: CGFloat(info.offsetY),
            width: CGFloat(info.width), height: CGFloat(info.height))

        let samplerName = (stringArg(a, "sampler") ?? "bicubic").lowercased()
        guard let sampler = Self.transformSamplers[samplerName] else {
            throw ToolError(
                message: "sampler must be nearest, bilinear, bicubic or lanczos "
                    + "(got \"\(samplerName)\")")
        }

        // The pivot: a named corner of the layer's CURRENT bounds, overridden
        // per axis by an explicit canvas coordinate.
        let anchor: CGPoint
        switch stringArg(a, "around") ?? "center" {
        case "center": anchor = CGPoint(x: rect.midX, y: rect.midY)
        case "top_left": anchor = CGPoint(x: rect.minX, y: rect.minY)
        case let other:
            throw ToolError(
                message: "around must be \"center\" or \"top_left\" (got \"\(other)\"); pass "
                    + "pivot_x / pivot_y for any other point.")
        }
        let pivot = CGPoint(
            x: CGFloat(try finiteArg(a, "pivot_x") ?? Double(anchor.x)),
            y: CGFloat(try finiteArg(a, "pivot_y") ?? Double(anchor.y)))

        let rotate = try finiteArg(a, "rotate")
        let uniformScale = try scaleArg(a, "scale")
        let scaleX = try scaleArg(a, "scale_x")
        let scaleY = try scaleArg(a, "scale_y")
        let translateX = try finiteArg(a, "translate_x")
        let translateY = try finiteArg(a, "translate_y")
        guard rotate != nil || uniformScale != nil || scaleX != nil || scaleY != nil
            || translateX != nil || translateY != nil
        else {
            throw ToolError(
                message: "transform_layer: nothing to change — pass at least one of rotate, "
                    + "scale, scale_x, scale_y, translate_x, translate_y.")
        }

        var transform = LayerTransform(pivot: pivot)
        transform.translation = CGVector(
            dx: CGFloat(translateX ?? 0), dy: CGFloat(translateY ?? 0))
        // Positive degrees turn CLOCKWISE on the flipped canvas, the same
        // sign the options bar's Angle field writes.
        if let rotate = rotate { transform.degrees = rotate }
        transform.scaleX = scaleX ?? uniformScale ?? 1
        transform.scaleY = scaleY ?? uniformScale ?? 1
        guard transform.isFinite else {
            throw ToolError(
                message: "Those parameters do not compose a usable transform — every value "
                    + "must be a finite number.")
        }
        guard !transform.isIdentity else {
            throw ToolError(
                message: "Those parameters leave the layer exactly where it is (a rotation "
                    + "that is a multiple of 360°, scales of 1, no translation), so there is "
                    + "nothing to transform.")
        }
        let matrix = transform.matrix

        // The core derives its destination extent exactly this way, so the
        // cases it would answer with NULL can be named precisely here.
        let extent = matrix.destinationExtent(of: rect)
        let int32Min = CGFloat(Int32.min)
        let int32Max = CGFloat(Int32.max)
        guard extent.width >= 1, extent.height >= 1,
            extent.minX >= int32Min, extent.minY >= int32Min,
            extent.maxX <= int32Max, extent.maxY <= int32Max
        else {
            throw ToolError(
                message: "The transformed layer would collapse to nothing or land outside the "
                    + "coordinates the core can address. Use a scale away from 0 and a "
                    + "translation that keeps the layer near the canvas.")
        }
        guard Double(extent.width) * Double(extent.height) <= Self.maxLayerPixels else {
            throw ToolError(
                message: "The transformed layer would be \(Int(extent.width))×"
                    + "\(Int(extent.height)) px, past the core's 100 megapixel ceiling for one "
                    + "layer (it is \(info.width)×\(info.height) px now). Scale down.")
        }
        guard abs(matrix.a * matrix.d - matrix.b * matrix.c) >= 1e-9 else {
            throw ToolError(
                message: "The composed matrix is degenerate (its determinant is ~0, so the "
                    + "layer collapses to a line): a scale of 0 or very near it. Use scales "
                    + "away from 0.")
        }

        // performPixelEdit is the pixel-rewrite chokepoint: a transform
        // resamples the pixels a text layer's description was rendered from,
        // so the description is dropped in the SAME edit (one undo step) and
        // reported back — the agent must never raise the UI's modal prompt.
        let rasterized: Bool
        do {
            rasterized = try performPixelEdit(
                document, "Transform Layer", pixelLayer: index
            ) { doc in
                doc.transformingLayer(index, matrix, sampler: sampler.filter)
            }
        } catch is ToolError {
            // performEdit's message is generic; everything the core can
            // refuse here is one of these two, and the checks above already
            // caught the common shapes.
            throw ToolError(
                message: "The core refused this transform: the composed matrix is degenerate "
                    + "(a zero or near-zero scale) or the resulting layer falls outside the "
                    + "sizes it allows. Try scales away from 0 and a smaller enlargement.")
        }

        let after = document.doc?.layerInfo(index)
        return try pixelEditResult(
            [
                "ok": true,
                "layer": index,
                // Where the layer landed: the outward-rounded bounding box of
                // the transformed corners, so a render can be checked against it.
                "bounds": [
                    "x": after?.offsetX ?? 0, "y": after?.offsetY ?? 0,
                    "width": after?.width ?? 0, "height": after?.height ?? 0,
                ],
                "applied": [
                    "rotate": Self.transformNumber(transform.degrees),
                    "scale_x": Self.transformNumber(Double(transform.scaleX)),
                    "scale_y": Self.transformNumber(Double(transform.scaleY)),
                    "translate_x": Self.transformNumber(translateX ?? 0),
                    "translate_y": Self.transformNumber(translateY ?? 0),
                    "pivot_x": Self.transformNumber(Double(pivot.x)),
                    "pivot_y": Self.transformNumber(Double(pivot.y)),
                    "sampler": sampler.name,
                ],
            ], layer: index, rasterizedText: rasterized)
    }

    // MARK: - Filters and geometry

    private func applyFilter(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = intArg(a, "layer") ?? document.activeLayerIndex
        let count = document.doc?.layerCount ?? 0
        guard index >= 0, index < count else {
            throw ToolError(message: "Layer \(index) is out of range (0..\(count - 1))")
        }
        let filter = try requiredString(a, "filter")
        let rasterized = try performPixelEdit(
            document, "Apply \(filter)", pixelLayer: index
        ) { doc in
            guard let layer = doc.layerImage(index),
                let filtered = self.filtered(layer, filter, a)
            else { return nil }
            return doc.withLayerPixels(index, filtered)
        }
        return try pixelEditResult(
            ["ok": true, "filter": filter, "layer": index],
            layer: index, rasterizedText: rasterized)
    }

    private func filtered(
        _ image: RasterImage, _ filter: String, _ a: [String: Any]
    ) -> RasterImage? {
        switch filter {
        case "grayscale": return image.grayscaled()
        case "invert": return image.inverted()
        case "sepia": return image.sepia()
        case "edge_detect": return image.edgeDetected()
        case "emboss": return image.embossed()
        case "blur": return image.blurred(sigma: doubleArg(a, "sigma") ?? 4)
        case "sharpen": return image.sharpened(amount: doubleArg(a, "amount") ?? 1)
        case "adjust":
            return image.adjusted(
                brightness: doubleArg(a, "brightness") ?? 0,
                contrast: doubleArg(a, "contrast") ?? 0,
                saturation: doubleArg(a, "saturation") ?? 0)
        case "levels":
            return image.levels(
                black: doubleArg(a, "black") ?? 0,
                white: doubleArg(a, "white") ?? 1,
                gamma: doubleArg(a, "gamma") ?? 1)
        case "hue_rotate": return image.hueRotated(degrees: doubleArg(a, "degrees") ?? 0)
        case "threshold": return image.thresholded(level: doubleArg(a, "level") ?? 0.5)
        case "posterize": return image.posterized(levels: intArg(a, "levels") ?? 4)
        case "pixelate": return image.pixelated(block: intArg(a, "block") ?? 8)
        case "add_noise":
            return image.noised(
                amount: doubleArg(a, "amount") ?? 0.2,
                seed: UInt64(bitPattern: Int64(intArg(a, "seed") ?? 1)))
        default: return nil
        }
    }

    // MARK: - Painting (brush, eraser, text)

    /// The layer a painting call targets ("layer" arg, default active) —
    /// same convention as apply_filter.
    private func paintLayerIndex(_ a: [String: Any], _ document: ImageDocument) throws -> Int {
        let index = intArg(a, "layer") ?? document.activeLayerIndex
        let count = document.doc?.layerCount ?? 0
        guard index >= 0, index < count else {
            throw ToolError(message: "Layer \(index) is out of range (0..\(count - 1))")
        }
        return index
    }

    /// Builds a canvas-sized premultiplied RGBA8 overlay (row 0 = top,
    /// drawing coordinates top-left-origin — the same format the canvas
    /// view's stroke pipeline uses), lets `draw` fill it, and composites
    /// it onto `layer` through the regular performEdit path. With
    /// `toMask` the very same overlay is painted into the layer's MASK
    /// instead (white reveals, black hides, the overlay's own alpha is
    /// the blend — `mode` and `alpha` do not apply there).
    ///
    /// Returns true when painting the layer's pixels dropped a text
    /// description (see performPixelEdit); a MASK stroke never does.
    @discardableResult
    private func paintOverlay(
        _ document: ImageDocument, layer: Int, actionName: String,
        mode: RzCompositeMode, alpha: Double, toMask: Bool = false,
        draw: (CGContext) -> Void
    ) throws -> Bool {
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let width = doc.width
        let height = doc.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        return try performPixelEdit(
            document, actionName, pixelLayer: toMask ? nil : layer
        ) { current in
            data.withUnsafeMutableBufferPointer { buffer -> RasterDocument? in
                guard let base = buffer.baseAddress,
                    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                    let context = CGContext(
                        data: base, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return nil }
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                // Strokes and text confine to the active selection, exactly
                // like the interactive tools.
                if let selection = editor(document)?.agentSelection {
                    selection.clip(context)
                }
                draw(context)
                if toMask {
                    return current.paintingLayerMask(
                        layer, overlay: base, w: width, h: height)
                }
                return current.paintingLayer(
                    layer, overlay: base, w: width, h: height, mode: mode, alpha: alpha)
            }
        }
    }

    private func parsePoints(_ a: [String: Any]) throws -> [CGPoint] {
        guard let raw = a["points"] as? [Any], !raw.isEmpty else {
            throw ToolError(message: "points must be a non-empty array of [x, y] pairs")
        }
        guard raw.count <= 10_000 else {
            throw ToolError(message: "Too many points (10,000 max)")
        }
        return try raw.map { entry in
            if let pair = entry as? [Any], pair.count == 2,
                let x = (pair[0] as? NSNumber)?.doubleValue,
                let y = (pair[1] as? NSNumber)?.doubleValue
            {
                return CGPoint(x: x, y: y)
            }
            if let object = entry as? [String: Any],
                let x = (object["x"] as? NSNumber)?.doubleValue,
                let y = (object["y"] as? NSNumber)?.doubleValue
            {
                return CGPoint(x: x, y: y)
            }
            throw ToolError(message: "Each point must be [x, y] or {\"x\": …, \"y\": …}")
        }
    }

    /// Hex color: #RGB, #RRGGBB, or #RRGGBBAA ('#' optional).
    private func parseColor(_ a: [String: Any], _ key: String, fallback: NSColor) throws
        -> NSColor
    {
        guard var hex = stringArg(a, key)?.trimmingCharacters(in: .whitespaces) else {
            return fallback
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
            throw ToolError(message: "\(key) must be a hex color like #RRGGBB or #RRGGBBAA")
        }
        let hasAlpha = hex.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha)
    }

    /// The brush/eraser "target" argument: the layer's pixels (default) or
    /// the layer's mask.
    private func paintTargetsMask(_ a: [String: Any]) throws -> Bool {
        switch stringArg(a, "target") ?? "layer" {
        case "layer": return false
        case "mask": return true
        case let other:
            throw ToolError(message: "target must be \"layer\" or \"mask\" (got \"\(other)\")")
        }
    }

    private func paintStroke(_ a: [String: Any], erase: Bool) throws -> String {
        let document = try target(a)
        let toMask = try paintTargetsMask(a)
        let layer =
            toMask
            ? try maskedLayerIndex(a, document, erase ? "erase" : "paint")
            : try paintLayerIndex(a, document)
        let points = try parsePoints(a)
        let size = CGFloat(min(max(doubleArg(a, "size") ?? 16, 1), 512))
        let opacity = min(max(doubleArg(a, "opacity") ?? 1, 0), 1)
        // In ERASE mode only the overlay's alpha matters. A MASK is coverage
        // rather than color — white reveals, black hides, whatever color was
        // asked for — and it carries the opacity in the stroke's own alpha,
        // since the mask-painting call takes no separate alpha.
        let color: NSColor
        if toMask {
            let level: CGFloat = erase ? 0 : 1
            color = NSColor(
                srgbRed: level, green: level, blue: level, alpha: CGFloat(opacity))
        } else if erase {
            color = .black
        } else {
            color = try parseColor(a, "color", fallback: .black)
        }
        let actionName: String
        if toMask {
            actionName = erase ? "Erase Mask" : "Paint Mask"
        } else {
            actionName = erase ? "Eraser Stroke" : "Brush Stroke"
        }
        let rasterized = try paintOverlay(
            document, layer: layer, actionName: actionName,
            mode: erase ? RZ_COMPOSITE_ERASE : RZ_COMPOSITE_OVER, alpha: opacity,
            toMask: toMask
        ) { context in
            context.setFillColor(color.cgColor)
            context.setStrokeColor(color.cgColor)
            if points.count == 1 {
                let p = points[0]
                context.fillEllipse(
                    in: CGRect(
                        x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
                return
            }
            context.setLineWidth(size)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: points[0])
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
        }
        return try pixelEditResult(
            [
                "ok": true, "action": actionName, "layer": layer, "points": points.count,
                "target": toMask ? "mask" : "layer",
            ], layer: layer, rasterizedText: rasterized)
    }

    private func addText(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let layer = try paintLayerIndex(a, document)
        let text = try requiredString(a, "text")
        guard let x = doubleArg(a, "x"), let y = doubleArg(a, "y") else {
            throw ToolError(message: "add_text requires x and y (top-left of the text block)")
        }
        let fontSize = CGFloat(min(max(doubleArg(a, "size") ?? 48, 4), 1000))
        let font: NSFont
        if let name = stringArg(a, "font") {
            guard let named = NSFont(name: name, size: fontSize) else {
                throw ToolError(message: "Unknown font \"\(name)\" — use a family or PostScript name")
            }
            font = named
        } else {
            font = .systemFont(ofSize: fontSize)
        }
        let color = try parseColor(a, "color", fallback: .black)
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])
        let canvasWidth = Double(document.doc?.width ?? 0)
        let box = CGRect(
            x: x, y: y, width: max(canvasWidth - x, 10), height: 100_000)
        let measured = attributed.boundingRect(
            with: NSSize(width: box.width, height: box.height),
            options: .usesLineFragmentOrigin)
        let rasterized = try paintOverlay(
            document, layer: layer, actionName: "Add Text",
            mode: RZ_COMPOSITE_OVER, alpha: 1
        ) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            attributed.draw(with: box, options: .usesLineFragmentOrigin)
            NSGraphicsContext.restoreGraphicsState()
        }
        return try pixelEditResult(
            [
                "ok": true, "layer": layer,
                "text_size": [
                    "width": Int(measured.width.rounded(.up)),
                    "height": Int(measured.height.rounded(.up)),
                ],
            ], layer: layer, rasterizedText: rasterized)
    }

    // MARK: - Text layers

    /// The family a text layer defaults to: the one the text tool's options
    /// bar starts on, so an agent-made layer looks like a hand-made one.
    /// Falls back to the system font's family when it is not installed.
    private static let defaultTextFamily: String = {
        let preferred = "Helvetica Neue"
        if NSFontManager.shared.availableFontFamilies.contains(preferred) { return preferred }
        return NSFont.systemFont(ofSize: 12).familyName ?? preferred
    }()

    /// The `font` argument of the text-layer tools: an installed font
    /// FAMILY, since the description stores a family and rebuilds the face
    /// from it. nil when the caller named none, so the caller can keep what
    /// the layer already says.
    private func textFamily(_ a: [String: Any], size: Double) throws -> String? {
        guard let name = stringArg(a, "font") else { return nil }
        guard
            NSFontManager.shared.font(
                withFamily: name, traits: [], weight: 5, size: CGFloat(size)) != nil
        else {
            throw ToolError(
                message: "No font family named \"\(name)\" is installed. A text layer stores a "
                    + "font FAMILY (\"Helvetica Neue\", \"Times New Roman\", …), not a "
                    + "PostScript face name; omit font to keep the current one.")
        }
        return name
    }

    /// The width the text lays out (and wraps) in: `wrap_width`, or from the
    /// text's left edge to the canvas's right edge — the same default
    /// add_text uses. The description has no wrap field, so an edit that
    /// omits it re-wraps at this default rather than at whatever width the
    /// layer was first laid out in.
    private func textWrapWidth(
        _ a: [String: Any], from x: Double, canvasWidth: Int
    ) throws -> CGFloat {
        guard let given = doubleArg(a, "wrap_width") else {
            return CGFloat(max(Double(canvasWidth) - x, 10))
        }
        guard given.isFinite, given >= 1 else {
            throw ToolError(message: "wrap_width must be at least 1 px")
        }
        return CGFloat(min(given, 1e6))
    }

    /// What a text-layer tool reports back: where the layer landed (the ink
    /// box plus a few px of slack for antialiasing and glyph overhang, so
    /// these are the layer's real bounds as get_document reports them) and
    /// the parameters it is now rendered from.
    private func textLayerResult(
        layer: Int, name: String, payload: TextLayerPayload, raster: TextLayerRaster,
        wrapWidth: CGFloat
    ) throws -> String {
        try jsonResult([
            "ok": true,
            "layer": layer,
            "name": name,
            "bounds": [
                "x": raster.offsetX, "y": raster.offsetY,
                "width": raster.width, "height": raster.height,
            ],
            "text": [
                "string": payload.string, "font": payload.font,
                "size": payload.size, "color": payload.color,
            ],
            "wrap_width": Int(wrapWidth.rounded()),
            "note": "Re-editable: change it with edit_text_layer. Painting on this layer "
                + "(brush, eraser, fill, gradient, add_text, apply_filter) drops the text "
                + "and leaves plain pixels.",
        ])
    }

    /// Creates a RE-EDITABLE text layer above the active one: the string,
    /// font, size and color become the layer's description and the pixels
    /// are only their rendering. Mirrors the text tool's own commit
    /// (EditorViewController.commitTextLayer) so both paths produce
    /// identical layers.
    private func addTextLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let text = try requiredString(a, "text")
        guard let x = doubleArg(a, "x"), let y = doubleArg(a, "y") else {
            throw ToolError(
                message: "add_text_layer requires x and y (the top-left of the text block)")
        }
        let size = min(max(doubleArg(a, "size") ?? 48, 4), 1000)
        let family = try textFamily(a, size: size) ?? Self.defaultTextFamily
        let color = try parseColor(a, "color", fallback: .black)
        let payload = TextLayerPayload(string: text, family: family, size: size, color: color)
        let wrapWidth = try textWrapWidth(a, from: x, canvasWidth: doc.width)
        guard
            let raster = TextLayer.render(
                payload, origin: CGPoint(x: x, y: y), wrapWidth: wrapWidth)
        else {
            throw ToolError(
                message: "Could not lay the text out — check that text is not empty and that "
                    + "x, y, size and wrap_width are sane numbers.")
        }
        let below = document.activeLayerIndex
        let name = TextLayer.layerName(for: text)
        // The core has no "layer from a buffer" constructor: add an empty
        // layer, then give it the pixels, the offset and the description.
        // Every op is pure, so only the final handle is committed — one
        // undo step.
        try performEdit(document, "Add Text Layer") { doc in
            let idx = below + 1
            guard let added = doc.addingLayer(above: below, name: name),
                let filled = added.withLayerPixels(
                    idx, rgba: raster.pixels, width: raster.width, height: raster.height),
                let moved = filled.withLayerOffset(idx, raster.offsetX, raster.offsetY)
            else { return nil }
            return moved.withTextPayload(idx, payload)
        }
        let index = min(below + 1, (document.doc?.layerCount ?? 1) - 1)
        document.activeLayerIndex = index
        // The edit's own notification went out before the active layer
        // moved, so the panel and status bar need this one to catch up.
        NotificationCenter.default.post(
            name: .imageDocumentImageDidChange, object: document, userInfo: ["isLive": false])
        return try textLayerResult(
            layer: index, name: name, payload: payload, raster: raster, wrapWidth: wrapWidth)
    }

    /// Re-renders an existing text layer from a changed description: any
    /// field the call omits keeps the value the layer already carries.
    /// Pixels, offset and description are replaced in one undo step.
    private func editTextLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard let info = doc.layerInfo(index) else {
            throw ToolError(message: "Layer \(index) could not be read")
        }
        guard let current = doc.textPayload(index) else {
            throw ToolError(
                message: "Layer \(index) (\"\(info.name)\") is not a text layer — it is plain "
                    + "pixels with no text to re-render (get_document reports a \"text\" "
                    + "object on the layers that have one). Make re-editable text with "
                    + "add_text_layer, or paint characters onto this layer with add_text.")
        }
        let text = stringArg(a, "text") ?? current.string
        guard !text.isEmpty else {
            throw ToolError(
                message: "text cannot be empty; remove the layer with delete_layer instead.")
        }
        let size = doubleArg(a, "size").map { min(max($0, 4), 1000) } ?? current.size
        let family = try textFamily(a, size: size) ?? current.font
        let color = try parseColor(a, "color", fallback: current.nsColor)
        let payload = TextLayerPayload(string: text, family: family, size: size, color: color)
        // Lay the new description out at the very origin the layer's pixels
        // were rendered from (the old description's padding is what its
        // offset includes), exactly as re-opening it with the text tool does.
        let origin = TextLayer.editorOrigin(
            offsetX: info.offsetX, offsetY: info.offsetY, payload: current)
        let wrapWidth = try textWrapWidth(a, from: Double(origin.x), canvasWidth: doc.width)
        guard let raster = TextLayer.render(payload, origin: origin, wrapWidth: wrapWidth) else {
            throw ToolError(
                message: "Could not lay the text out — check size and wrap_width.")
        }
        let name = TextLayer.layerName(for: text)
        // The name follows the text only while it still IS the text: a name
        // somebody typed themselves survives the re-render.
        let nameFollowsText = info.name == TextLayer.layerName(for: current.string)
        try performEdit(document, "Edit Text Layer") { doc in
            guard let filled = doc.withLayerPixels(
                    index, rgba: raster.pixels, width: raster.width, height: raster.height),
                let moved = filled.withLayerOffset(index, raster.offsetX, raster.offsetY),
                let described = moved.withTextPayload(index, payload)
            else { return nil }
            guard nameFollowsText else { return described }
            return described.withLayerName(index, name) ?? described
        }
        return try textLayerResult(
            layer: index, name: nameFollowsText ? name : info.name, payload: payload,
            raster: raster, wrapWidth: wrapWidth)
    }

    // MARK: - Selection, fill, gradient

    private func editor(_ document: ImageDocument) -> EditorViewController? {
        document.windowControllers
            .compactMap { $0.contentViewController as? EditorViewController }
            .first
    }

    /// The document's live selection mask (nil when nothing is selected
    /// or the document has no editor window).
    private func selectionMask(_ document: ImageDocument) -> [UInt8]? {
        editor(document)?.agentSelection?.maskBytes()
    }

    /// The select_* tools' optional "mode" argument (default replace).
    private func selectionMode(_ a: [String: Any]) throws -> SelectionCombineMode {
        switch stringArg(a, "mode") ?? "replace" {
        case "replace": return .replace
        case "add": return .add
        case "subtract": return .subtract
        case "intersect": return .intersect
        case let other:
            throw ToolError(
                message: "mode must be replace, add, subtract, or intersect (got \"\(other)\")")
        }
    }

    private func applySelection(
        _ document: ImageDocument, _ shape: CanvasSelection.Shape, mode: SelectionCombineMode
    ) throws -> String {
        guard let editorVC = editor(document) else {
            throw ToolError(message: "The document has no editor window to hold a selection.")
        }
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard
            let selection = CanvasSelection(
                shape: shape, canvasWidth: doc.width, canvasHeight: doc.height)
        else {
            throw ToolError(message: "The selection would be empty.")
        }
        return try setCombined(
            editorVC, CanvasSelection.combine(editorVC.agentSelection, with: selection, mode: mode))
    }

    /// Applies a combine/modify result: an empty (nil) result deselects,
    /// reported in-band rather than as an error.
    private func setCombined(
        _ editorVC: EditorViewController, _ selection: CanvasSelection?
    ) throws -> String {
        guard let selection = selection else {
            editorVC.agentSetSelection(nil)
            return try jsonResult([
                "ok": true, "selection_empty": true,
                "note": "The resulting selection is empty; the selection was cleared.",
            ])
        }
        editorVC.agentSetSelection(selection)
        let b = selection.bounds
        return try jsonResult([
            "ok": true,
            "bounds": [
                "x": Int(b.minX), "y": Int(b.minY),
                "width": Int(b.width), "height": Int(b.height),
            ],
        ])
    }

    private func selectShape(
        _ a: [String: Any], _ make: (CGRect) -> CanvasSelection.Shape
    ) throws -> String {
        let document = try target(a)
        guard let x = intArg(a, "x"), let y = intArg(a, "y"),
            let w = intArg(a, "width"), let h = intArg(a, "height"), w > 0, h > 0
        else {
            throw ToolError(message: "Requires x, y, width, height (width/height > 0)")
        }
        return try applySelection(
            document, make(CGRect(x: x, y: y, width: w, height: h)), mode: selectionMode(a))
    }

    private func selectPolygon(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let points = try parsePoints(a)
        guard points.count >= 3 else {
            throw ToolError(message: "A polygon selection needs at least 3 points")
        }
        return try applySelection(document, .polygon(points), mode: selectionMode(a))
    }

    private func selectMagicWand(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc, let x = intArg(a, "x"), let y = intArg(a, "y") else {
            throw ToolError(message: "select_magic_wand requires x and y")
        }
        let tolerance = intArg(a, "tolerance") ?? 32
        let contiguous = boolArg(a, "contiguous") ?? true
        guard
            let mask = doc.magicWand(
                x: x, y: y, tolerance: tolerance, contiguous: contiguous)
        else {
            throw ToolError(message: "The seed point is outside the canvas")
        }
        return try applySelection(document, .mask(mask), mode: selectionMode(a))
    }

    private func deselect(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        editor(document)?.agentSetSelection(nil)
        return try jsonResult(["ok": true])
    }

    private func modifySelection(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let editorVC = editor(document) else {
            throw ToolError(message: "The document has no editor window to hold a selection.")
        }
        guard let selection = editorVC.agentSelection else {
            throw ToolError(
                message: "There is no selection to modify. Make one with the select_* tools.")
        }
        let modified: CanvasSelection?
        switch try requiredString(a, "operation") {
        case "invert":
            modified = selection.inverted()
        case "feather":
            guard let radius = doubleArg(a, "radius"), radius.isFinite, radius > 0 else {
                throw ToolError(message: "feather requires a positive radius (px)")
            }
            modified = selection.feathered(by: min(radius, 250))
        case let other:
            throw ToolError(message: "operation must be \"invert\" or \"feather\" (got \"\(other)\")")
        }
        return try setCombined(editorVC, modified)
    }

    private func fill(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        guard let x = intArg(a, "x"), let y = intArg(a, "y") else {
            throw ToolError(message: "fill requires x and y (the seed point)")
        }
        let rgba = try colorRGBA(parseColor(a, "color", fallback: .black))
        let tolerance = intArg(a, "tolerance") ?? 32
        let contiguous = boolArg(a, "contiguous") ?? true
        let mask = selectionMask(document)
        let rasterized = try performPixelEdit(document, "Fill", pixelLayer: index) { doc in
            doc.bucketFilled(
                index, x: x, y: y, tolerance: tolerance, rgba: rgba,
                contiguous: contiguous, mask: mask)
        }
        return try pixelEditResult(
            ["ok": true, "layer": index], layer: index, rasterizedText: rasterized)
    }

    private func gradient(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        guard let x0 = doubleArg(a, "x0"), let y0 = doubleArg(a, "y0"),
            let x1 = doubleArg(a, "x1"), let y1 = doubleArg(a, "y1")
        else {
            throw ToolError(message: "gradient requires x0, y0, x1, y1")
        }
        let start = try colorRGBA(parseColor(a, "start_color", fallback: .black))
        let end: [UInt8]
        if stringArg(a, "end_color") != nil {
            end = try colorRGBA(parseColor(a, "end_color", fallback: .clear))
        } else {
            end = [0, 0, 0, 0] // fade to transparent
        }
        let kind: RzGradientKind
        switch stringArg(a, "shape") ?? "linear" {
        case "linear": kind = RZ_GRADIENT_LINEAR
        case "radial": kind = RZ_GRADIENT_RADIAL
        default: throw ToolError(message: "shape must be \"linear\" or \"radial\"")
        }
        let mask = selectionMask(document)
        let rasterized = try performPixelEdit(document, "Gradient", pixelLayer: index) { doc in
            doc.gradiented(
                index, from: CGPoint(x: x0, y: y0), to: CGPoint(x: x1, y: y1),
                start: start, end: end, kind: kind, mask: mask)
        }
        return try pixelEditResult(
            ["ok": true, "layer": index], layer: index, rasterizedText: rasterized)
    }

    /// clear_selection: erases the window's live selection out of a layer,
    /// proportionally to its coverage (a feathered selection leaves a soft
    /// edge). Nothing selected is a recoverable error, not a whole-layer wipe.
    private func clearSelection(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        guard let mask = selectionMask(document) else {
            throw ToolError(
                message: "There is no selection to clear. Make one first with select_rect, "
                    + "select_ellipse, select_polygon or select_magic_wand.")
        }
        let rasterized = try performPixelEdit(document, "Clear", pixelLayer: index) { doc in
            doc.clearingSelection(index, mask: mask)
        }
        return try pixelEditResult(
            ["ok": true, "layer": index], layer: index, rasterizedText: rasterized)
    }

    /// sRGB straight-alpha bytes of a parsed color.
    private func colorRGBA(_ color: NSColor) throws -> [UInt8] {
        guard let c = color.usingColorSpace(.sRGB) else {
            throw ToolError(message: "Could not convert the color")
        }
        return [
            UInt8((c.redComponent * 255).rounded()),
            UInt8((c.greenComponent * 255).rounded()),
            UInt8((c.blueComponent * 255).rounded()),
            UInt8((c.alphaComponent * 255).rounded()),
        ]
    }

    private func rotate(_ a: [String: Any]) throws -> String {
        let degrees = intArg(a, "degrees") ?? 90
        let actionName = "Rotate \(degrees)°"
        switch degrees {
        case 90: return try docEdit(a, actionName) { $0.rotated90() }
        case 180: return try docEdit(a, actionName) { $0.rotated180() }
        case 270, -90: return try docEdit(a, actionName) { $0.rotated270() }
        default: throw ToolError(message: "degrees must be 90, 180, 270, or -90 (clockwise)")
        }
    }

    private func flip(_ a: [String: Any]) throws -> String {
        switch try requiredString(a, "axis") {
        case "horizontal": return try docEdit(a, "Flip Horizontal") { $0.flippedH() }
        case "vertical": return try docEdit(a, "Flip Vertical") { $0.flippedV() }
        default: throw ToolError(message: "axis must be \"horizontal\" or \"vertical\"")
        }
    }

    private func crop(_ a: [String: Any]) throws -> String {
        guard let x = intArg(a, "x"), let y = intArg(a, "y"),
            let w = intArg(a, "width"), let h = intArg(a, "height")
        else {
            throw ToolError(message: "crop requires x, y, width, height")
        }
        return try docEdit(a, "Crop") { $0.cropped(x: x, y: y, w: w, h: h) }
    }

    private func imageSize(_ a: [String: Any]) throws -> String {
        guard let w = intArg(a, "width"), let h = intArg(a, "height") else {
            throw ToolError(message: "image_size requires width and height")
        }
        let filters: [String: RzResizeFilter] = [
            "nearest": RZ_FILTER_NEAREST, "bilinear": RZ_FILTER_BILINEAR,
            "catmull-rom": RZ_FILTER_CATMULL_ROM, "lanczos3": RZ_FILTER_LANCZOS3,
        ]
        let filter = try stringArg(a, "filter").map { name in
            guard let match = filters[name] else {
                throw ToolError(message: "filter must be one of \(filters.keys.sorted())")
            }
            return match
        } ?? RZ_FILTER_LANCZOS3
        return try docEdit(a, "Image Size") { $0.resized(w: w, h: h, filter: filter) }
    }

    private func canvasSize(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard let w = intArg(a, "width"), let h = intArg(a, "height") else {
            throw ToolError(message: "canvas_size requires width and height")
        }
        let anchors: [String: (col: Int, row: Int)] = [
            "top-left": (0, 0), "top": (1, 0), "top-right": (2, 0),
            "left": (0, 1), "center": (1, 1), "right": (2, 1),
            "bottom-left": (0, 2), "bottom": (1, 2), "bottom-right": (2, 2),
        ]
        let anchorName = stringArg(a, "anchor") ?? "center"
        guard let anchor = anchors[anchorName] else {
            throw ToolError(message: "anchor must be one of \(anchors.keys.sorted())")
        }
        // Matches the Canvas Size sheet: the anchor's column/row chooses how
        // much of the size delta lands left/above the old canvas origin.
        let originX = Int((Double(w - doc.width) * Double(anchor.col) / 2.0).rounded())
        let originY = Int((Double(h - doc.height) * Double(anchor.row) / 2.0).rounded())
        try performEdit(document, "Canvas Size") {
            $0.canvasResized(w: w, h: h, originX: originX, originY: originY)
        }
        return try jsonResult(["ok": true, "document": summary(document)])
    }

    // MARK: - Undo, export

    private func undoRedo(_ a: [String: Any], redo: Bool) throws -> String {
        let document = try target(a)
        guard let manager = document.undoManager else {
            throw ToolError(message: "No undo manager")
        }
        if redo {
            guard manager.canRedo else { throw ToolError(message: "Nothing to redo") }
            manager.redo()
        } else {
            guard manager.canUndo else { throw ToolError(message: "Nothing to undo") }
            manager.undo()
        }
        return try jsonResult(["ok": true, "document": summary(document)])
    }

    private func saveCopy(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let image = document.projection ?? document.doc?.flattened() else {
            throw ToolError(message: "Could not flatten the document")
        }
        let path = try requiredString(a, "path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let formatName = stringArg(a, "format") ?? url.pathExtension.lowercased()
        let format = ExportFormat.allCases.first {
            $0.fileExtension == formatName || $0.displayName.lowercased() == formatName
        }
        guard let format = format else {
            let names = ExportFormat.allCases.map { $0.fileExtension }.joined(separator: ", ")
            throw ToolError(message: "Cannot infer the format; pass format as one of: \(names)")
        }
        let quality = intArg(a, "jpeg_quality") ?? document.jpegExportQuality
        do {
            try image.save(to: url, format: format.rzFormat, jpegQuality: quality)
        } catch {
            throw ToolError(message: error.localizedDescription)
        }
        return try jsonResult(["ok": true, "path": url.path, "format": format.displayName])
    }

    // MARK: - Argument helpers

    private func intArg(_ a: [String: Any], _ key: String) -> Int? {
        (a[key] as? NSNumber)?.intValue ?? (a[key] as? String).flatMap(Int.init)
    }

    private func doubleArg(_ a: [String: Any], _ key: String) -> Double? {
        (a[key] as? NSNumber)?.doubleValue ?? (a[key] as? String).flatMap(Double.init)
    }

    private func boolArg(_ a: [String: Any], _ key: String) -> Bool? {
        guard let number = a[key] as? NSNumber else { return nil }
        return number.boolValue
    }

    private func stringArg(_ a: [String: Any], _ key: String) -> String? {
        a[key] as? String
    }

    private func requiredString(_ a: [String: Any], _ key: String) throws -> String {
        guard let value = stringArg(a, key), !value.isEmpty else {
            throw ToolError(message: "Missing required argument: \(key)")
        }
        return value
    }

    // MARK: - Result encoding

    private func callResult(content: [[String: Any]], isError: Bool) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["content": content, "isError": isError])
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonResult(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try callResult(
            content: [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            isError: false)
    }

    private func errorResult(_ message: String) -> String {
        let content: [[String: Any]] = [["type": "text", "text": message]]
        let fallback = #"{"content":[{"type":"text","text":"tool failed"}],"isError":true}"#
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["content": content, "isError": true])
        else { return fallback }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Catalog

    private func tool(
        _ name: String, _ description: String,
        _ properties: [String: Any], required: [String] = []
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object", "properties": properties, "required": required,
            ] as [String: Any],
        ]
    }

    private static let docIDProperty: [String: Any] = [
        "type": "integer",
        "description": "Target document id from list_documents; omit for the frontmost document.",
    ]

    func catalogJSON() throws -> String {
        let docID = Self.docIDProperty
        let index: [String: Any] = [
            "type": "integer",
            "description": "Layer index (0 = bottom); omit for the active layer.",
        ]
        let selectionMode: [String: Any] = [
            "type": "string",
            "enum": ["replace", "add", "subtract", "intersect"],
            "description": "How the new shape combines with the current selection "
                + "(default replace). add unions, subtract removes the new shape from "
                + "the current selection, intersect keeps the overlap; an empty result "
                + "clears the selection.",
        ]
        let blendNames = RzBlendMode.allBlendModes.map { $0.1 }
        let catalog: [[String: Any]] = [
            tool(
                "list_documents",
                "Lists the images open in Rasterize with their ids, sizes, and layer counts.",
                [:]),
            tool(
                "open_document",
                "Opens an image file (PNG, JPEG, PSD, TIFF, BMP, GIF, WebP, RZ) in a new "
                    + "editor window and returns its document id.",
                ["path": ["type": "string", "description": "Absolute or ~ path to the file."]],
                required: ["path"]),
            tool(
                "get_document",
                "Full state of one document: canvas size and every layer's name, size, offset, "
                    + "opacity, blend mode, visibility, and layer mask (has_mask, mask_enabled). "
                    + "A re-editable TEXT layer also reports a text object (string, font, size, "
                    + "color) — those are the layers edit_text_layer can change; a layer without "
                    + "that key is plain pixels. Layer index 0 is the bottom layer; offsets are "
                    + "measured from the canvas top-left corner, y increasing down.",
                ["document_id": docID]),
            tool(
                "render",
                "Renders the flattened canvas (or one layer) as a PNG image so you can see it. "
                    + "Use this to inspect the picture before and after edits.",
                [
                    "document_id": docID, "layer": index,
                    "max_side": [
                        "type": "integer",
                        "description": "Longest output side in px (64-4096, default 1024).",
                    ],
                ]),
            tool(
                "set_active_layer",
                "Selects the layer that untargeted edits apply to.",
                ["index": ["type": "integer"], "document_id": docID], required: ["index"]),
            tool(
                "new_layer",
                "Adds an empty transparent layer above the active layer and selects it.",
                ["name": ["type": "string"], "document_id": docID]),
            tool(
                "duplicate_layer", "Duplicates a layer.",
                ["index": index, "document_id": docID]),
            tool(
                "delete_layer", "Deletes a layer (the last layer cannot be deleted).",
                ["index": index, "document_id": docID]),
            tool(
                "merge_down", "Merges a layer into the one below it.",
                ["index": index, "document_id": docID]),
            tool(
                "flatten_image", "Flattens all layers into one.",
                ["document_id": docID]),
            tool(
                "reorder_layer", "Moves a layer to a new stack position.",
                [
                    "from": ["type": "integer"], "to": ["type": "integer"],
                    "document_id": docID,
                ], required: ["from", "to"]),
            tool(
                "set_layer_properties",
                "Changes any of a layer's name, opacity (0-1), blend mode, visibility, or "
                    + "pixel offset in one undoable step.",
                [
                    "index": index,
                    "name": ["type": "string"],
                    "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                    "blend_mode": ["type": "string", "enum": blendNames],
                    "visible": ["type": "boolean"],
                    "offset_x": ["type": "integer"],
                    "offset_y": ["type": "integer"],
                    "document_id": docID,
                ]),
            tool(
                "transform_layer",
                "Rotates, scales and/or moves ONE layer's pixels in a single resample — the "
                    + "same pipeline as the app's Free Transform (⌘T). The rotation and the "
                    + "scales act around a pivot (the centre of the layer's CURRENT bounds by "
                    + "default), then the translation is added; the layer is resampled once "
                    + "into the outward-rounded bounding box of its transformed corners, so "
                    + "its offset AND size both change, and it may end up extending past the "
                    + "canvas. The canvas and every other layer are untouched, and a layer "
                    + "mask rides along, resampled identically. Pass at least one of rotate, "
                    + "scale, scale_x, scale_y, translate_x, translate_y; the result reports "
                    + "the layer's new bounds so you can verify placement. For whole-document "
                    + "geometry use rotate / flip / image_size instead. NOTE: this rewrites "
                    + "the layer's pixels, so on a re-editable TEXT layer it drops the text "
                    + "description (undo restores it) — to just MOVE such a layer and keep "
                    + "its text, set offset_x / offset_y with set_layer_properties.",
                [
                    "layer": index,
                    "rotate": [
                        "type": "number",
                        "description": "Rotation in degrees around the pivot. POSITIVE IS "
                            + "CLOCKWISE on screen (canvas y grows downward), matching the "
                            + "app's Angle field. Default 0.",
                    ],
                    "scale": [
                        "type": "number",
                        "description": "Uniform scale multiplier for both axes: 1 = unchanged "
                            + "(default), 0.5 = half size, 2 = double, negative mirrors. "
                            + "scale_x / scale_y override it per axis. Magnitudes are clamped "
                            + "to 0.001-100 and 0 is refused.",
                    ],
                    "scale_x": [
                        "type": "number",
                        "description": "Horizontal scale multiplier, overriding scale "
                            + "(1 = unchanged, negative mirrors left-right).",
                    ],
                    "scale_y": [
                        "type": "number",
                        "description": "Vertical scale multiplier, overriding scale "
                            + "(1 = unchanged, negative mirrors top-bottom).",
                    ],
                    "translate_x": [
                        "type": "number",
                        "description": "Move right by this many canvas px (negative = left), "
                            + "applied after the rotation and scale.",
                    ],
                    "translate_y": [
                        "type": "number",
                        "description": "Move down by this many canvas px (negative = up), "
                            + "applied after the rotation and scale.",
                    ],
                    "around": [
                        "type": "string",
                        "enum": ["center", "top_left"],
                        "description": "The pivot the rotation and scale turn/grow around: "
                            + "\"center\" (default) or \"top_left\" of the layer's current "
                            + "bounds. pivot_x / pivot_y override it.",
                    ],
                    "pivot_x": [
                        "type": "number",
                        "description": "Explicit pivot x in canvas px; overrides around on "
                            + "this axis.",
                    ],
                    "pivot_y": [
                        "type": "number",
                        "description": "Explicit pivot y in canvas px; overrides around on "
                            + "this axis.",
                    ],
                    "sampler": [
                        "type": "string",
                        "enum": ["nearest", "bilinear", "bicubic", "lanczos"],
                        "description": "Resampling filter, default bicubic (Catmull-Rom). "
                            + "nearest keeps hard pixel edges (pixel art), lanczos is "
                            + "sharpest for big reductions. Whole-pixel moves and mirrors "
                            + "(scale -1) copy pixels losslessly whatever this says; every "
                            + "rotation is resampled, so for a lossless quarter turn of the "
                            + "WHOLE image use the rotate tool instead.",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "add_layer_mask",
                "Gives a layer a mask: a grayscale coverage channel that gates the layer's "
                    + "alpha without touching its pixels (white shows, black hides, grays are "
                    + "partial), so hiding is non-destructive and reversible. The mask is the "
                    + "layer's size and moves with it. Replaces any existing mask and enables "
                    + "it. Paint it afterwards with brush_stroke / eraser_stroke and "
                    + "target: \"mask\".",
                [
                    "layer": index,
                    "kind": [
                        "type": "string",
                        "enum": ["reveal_all", "hide_all", "from_selection"],
                        "description": "reveal_all (default) starts fully white — nothing "
                            + "hidden yet; hide_all starts black — the layer disappears until "
                            + "you paint it back; from_selection builds the mask from the "
                            + "CURRENT selection (selected shows, the rest hides), so it "
                            + "requires an active selection from a select_* tool.",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "remove_layer_mask",
                "Removes a layer's mask. With apply: true the coverage is first BAKED into "
                    + "the layer's alpha — permanent, pixels lost, and it bakes regardless of "
                    + "whether the mask was enabled — so what the mask hid becomes really "
                    + "erased. With apply: false (the default) the mask is simply discarded "
                    + "and the layer is revealed in full again, pixels untouched.",
                [
                    "layer": index,
                    "apply": [
                        "type": "boolean",
                        "description": "Bake the mask into the layer's alpha before dropping "
                            + "it (default false = discard it).",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "set_layer_mask_enabled",
                "Turns a layer's mask on or off. A disabled mask is kept (and saved) but "
                    + "ignored while compositing, so the layer shows in full — useful to "
                    + "compare with and without. Errors when the layer has no mask.",
                [
                    "layer": index,
                    "enabled": ["type": "boolean"],
                    "document_id": docID,
                ], required: ["enabled"]),
            tool(
                "apply_filter",
                "Applies a filter or adjustment to one layer's pixels. Filters and their "
                    + "parameters: grayscale, invert, sepia, edge_detect, emboss (none); "
                    + "blur (sigma, default 4); sharpen (amount, default 1); adjust "
                    + "(brightness, contrast, saturation, each -1..1, default 0); levels "
                    + "(black 0-1, white 0-1, gamma 0.1-10); hue_rotate (degrees); threshold "
                    + "(level 0-1); posterize (levels 2-64); pixelate (block 1-1024); "
                    + "add_noise (amount 0-1, seed).",
                [
                    "filter": [
                        "type": "string",
                        "enum": [
                            "grayscale", "invert", "sepia", "edge_detect", "emboss", "blur",
                            "sharpen", "adjust", "levels", "hue_rotate", "threshold",
                            "posterize", "pixelate", "add_noise",
                        ],
                    ],
                    "layer": index,
                    "sigma": ["type": "number"], "amount": ["type": "number"],
                    "brightness": ["type": "number"], "contrast": ["type": "number"],
                    "saturation": ["type": "number"], "black": ["type": "number"],
                    "white": ["type": "number"], "gamma": ["type": "number"],
                    "degrees": ["type": "number"], "level": ["type": "number"],
                    "levels": ["type": "integer"], "block": ["type": "integer"],
                    "seed": ["type": "integer"],
                    "document_id": docID,
                ], required: ["filter"]),
            tool(
                "brush_stroke",
                "Paints a brush stroke onto a layer's pixels: a smooth polyline through "
                    + "points (canvas coordinates) with round caps and joins. One point "
                    + "paints a dot. Draw shapes with several strokes; use render to check "
                    + "the result. With target: \"mask\" the same stroke paints the layer's "
                    + "mask instead, revealing what it covers.",
                [
                    "points": [
                        "type": "array",
                        "description": "[[x, y], …] along the stroke, in canvas px.",
                        "items": [
                            "type": "array", "items": ["type": "number"],
                            "minItems": 2, "maxItems": 2,
                        ],
                        "minItems": 1, "maxItems": 10_000,
                    ],
                    "size": [
                        "type": "number",
                        "description": "Stroke width in px (1-512, default 16).",
                    ],
                    "color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA (default #000000). "
                            + "Ignored when target is \"mask\".",
                    ],
                    "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                    "layer": index,
                    "target": [
                        "type": "string",
                        "enum": ["layer", "mask"],
                        "description": "What the stroke paints: \"layer\" (default) the "
                            + "layer's own pixels, \"mask\" the layer's mask, where the "
                            + "stroke REVEALS what it covers. A mask is coverage, not color, "
                            + "so a mask stroke is forced to WHITE whatever color you pass, "
                            + "and opacity becomes partial coverage. The layer must already "
                            + "have a mask (add_layer_mask).",
                    ],
                    "document_id": docID,
                ], required: ["points"]),
            tool(
                "eraser_stroke",
                "Erases along a polyline (same geometry as brush_stroke): pixels under the "
                    + "stroke become transparent. opacity is the eraser strength. With "
                    + "target: \"mask\" it hides through the layer's mask instead, leaving "
                    + "the pixels intact.",
                [
                    "points": [
                        "type": "array",
                        "description": "[[x, y], …] along the stroke, in canvas px.",
                        "items": [
                            "type": "array", "items": ["type": "number"],
                            "minItems": 2, "maxItems": 2,
                        ],
                        "minItems": 1, "maxItems": 10_000,
                    ],
                    "size": [
                        "type": "number",
                        "description": "Stroke width in px (1-512, default 16).",
                    ],
                    "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                    "layer": index,
                    "target": [
                        "type": "string",
                        "enum": ["layer", "mask"],
                        "description": "What the stroke erases: \"layer\" (default) makes the "
                            + "layer's own pixels transparent, \"mask\" paints the layer's "
                            + "mask so it HIDES what the stroke covers while the pixels stay "
                            + "intact (undo it by brushing the mask with target: \"mask\"). "
                            + "A mask is coverage, not color, so a mask stroke is forced to "
                            + "BLACK, and opacity becomes partial coverage. The layer must "
                            + "already have a mask (add_layer_mask).",
                    ],
                    "document_id": docID,
                ], required: ["points"]),
            tool(
                "add_text",
                "Rasterizes text onto a layer's pixels — the characters become pixels and "
                    + "cannot be changed afterwards, so prefer add_text_layer when the text "
                    + "may need editing. x,y is the TOP-LEFT corner of the text block; long "
                    + "lines wrap at the canvas edge and \\n starts a new line. Returns the "
                    + "rendered text size so you can position follow-ups.",
                [
                    "text": ["type": "string"],
                    "x": ["type": "number"], "y": ["type": "number"],
                    "size": [
                        "type": "number",
                        "description": "Font size in px (4-1000, default 48).",
                    ],
                    "font": [
                        "type": "string",
                        "description": "Font family or PostScript name (default: system font).",
                    ],
                    "color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA (default #000000).",
                    ],
                    "layer": index,
                    "document_id": docID,
                ], required: ["text", "x", "y"]),
            tool(
                "add_text_layer",
                "Adds a RE-EDITABLE text layer above the active layer and selects it. The "
                    + "layer remembers the string, font, size and color it was rendered from "
                    + "(get_document reports them, edit_text_layer changes them, and they "
                    + "survive saving to .rz), unlike add_text which just bakes characters "
                    + "into pixels. x,y is the TOP-LEFT corner of the text block, positioned "
                    + "exactly like add_text; \\n starts a new line and long lines wrap at "
                    + "wrap_width. Returns the new layer's index and bounds. NOTE: painting "
                    + "on the layer afterwards (brush, eraser, fill, gradient, add_text, "
                    + "apply_filter) drops the text and leaves plain pixels.",
                [
                    "text": ["type": "string"],
                    "x": ["type": "number"], "y": ["type": "number"],
                    "size": [
                        "type": "number",
                        "description": "Font size in px (4-1000, default 48).",
                    ],
                    "font": [
                        "type": "string",
                        "description": "Installed font FAMILY name, e.g. \"Helvetica Neue\" "
                            + "or \"Times New Roman\" (not a PostScript face name). "
                            + "Default: the text tool's own default family.",
                    ],
                    "color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA (default #000000).",
                    ],
                    "wrap_width": [
                        "type": "number",
                        "description": "Width in px the lines wrap at; default is from x to "
                            + "the canvas's right edge.",
                    ],
                    "document_id": docID,
                ], required: ["text", "x", "y"]),
            tool(
                "edit_text_layer",
                "Re-renders a text layer made by add_text_layer (or by the app's text tool) "
                    + "from changed parameters: pass any subset of text, font, size, color "
                    + "and wrap_width, and everything you omit keeps the layer's current "
                    + "value. The layer keeps its position (the text block is re-laid-out "
                    + "from the same top-left corner, so the bounds follow the new text), "
                    + "its opacity, blend mode and stacking. Errors when the target layer is "
                    + "not a text layer — add_text_layer makes one. Returns the resulting "
                    + "bounds. wrap_width is not stored on the layer, so omitting it re-wraps "
                    + "at the canvas's right edge; pass it to keep a narrower block narrow.",
                [
                    "layer": index,
                    "text": ["type": "string"],
                    "size": [
                        "type": "number",
                        "description": "Font size in px (4-1000).",
                    ],
                    "font": [
                        "type": "string",
                        "description": "Installed font FAMILY name (not a PostScript face "
                            + "name).",
                    ],
                    "color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA.",
                    ],
                    "wrap_width": [
                        "type": "number",
                        "description": "Width in px the lines wrap at.",
                    ],
                    "document_id": docID,
                ]),
            tool(
                "select_rect",
                "Selects a rectangle (canvas coordinates). Selections confine "
                    + "brush/eraser strokes, fill, and gradient, and define Crop.",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "mode": selectionMode,
                    "document_id": docID,
                ], required: ["x", "y", "width", "height"]),
            tool(
                "select_ellipse",
                "Selects an ellipse inscribed in the given rectangle.",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "mode": selectionMode,
                    "document_id": docID,
                ], required: ["x", "y", "width", "height"]),
            tool(
                "select_polygon",
                "Selects a polygon through the given vertices (at least 3, "
                    + "closed automatically).",
                [
                    "points": [
                        "type": "array",
                        "description": "[[x, y], …] polygon vertices in canvas px.",
                        "items": [
                            "type": "array", "items": ["type": "number"],
                            "minItems": 2, "maxItems": 2,
                        ],
                        "minItems": 3, "maxItems": 10_000,
                    ],
                    "mode": selectionMode,
                    "document_id": docID,
                ], required: ["points"]),
            tool(
                "select_magic_wand",
                "Selects the region of similar color around a seed point, sampled "
                    + "from the flattened composite (what you see in a render). "
                    + "tolerance is the max per-channel difference (0-255, default 32); "
                    + "contiguous (default true) limits to the connected region.",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "tolerance": ["type": "integer", "minimum": 0, "maximum": 255],
                    "contiguous": ["type": "boolean"],
                    "mode": selectionMode,
                    "document_id": docID,
                ], required: ["x", "y"]),
            tool(
                "deselect", "Clears the selection.", ["document_id": docID]),
            tool(
                "modify_selection",
                "Transforms the current selection (errors when nothing is selected): "
                    + "invert selects the complement over the canvas; feather "
                    + "Gaussian-softens the selection edge by radius px, so later "
                    + "fills, gradients, and strokes fade out across it. An empty "
                    + "result clears the selection.",
                [
                    "operation": ["type": "string", "enum": ["invert", "feather"]],
                    "radius": [
                        "type": "number",
                        "description": "Feather radius in px (0-250; required for feather).",
                    ],
                    "document_id": docID,
                ], required: ["operation"]),
            tool(
                "fill",
                "Bucket fill: flood-fills the similar-color region around the seed "
                    + "point on a layer's own pixels with a color. Respects the active "
                    + "selection. tolerance as in select_magic_wand.",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA (default #000000).",
                    ],
                    "tolerance": ["type": "integer", "minimum": 0, "maximum": 255],
                    "contiguous": ["type": "boolean"],
                    "layer": index,
                    "document_id": docID,
                ], required: ["x", "y"]),
            tool(
                "gradient",
                "Paints a two-color gradient over a layer (the whole layer, or the "
                    + "active selection if one exists). Linear runs along "
                    + "(x0,y0)->(x1,y1); radial spreads from (x0,y0) with radius to "
                    + "(x1,y1). end_color defaults to transparent (a fade-out).",
                [
                    "x0": ["type": "number"], "y0": ["type": "number"],
                    "x1": ["type": "number"], "y1": ["type": "number"],
                    "start_color": [
                        "type": "string",
                        "description": "Hex color, #RRGGBB or #RRGGBBAA.",
                    ],
                    "end_color": [
                        "type": "string",
                        "description": "Hex color; omit to fade to transparent.",
                    ],
                    "shape": ["type": "string", "enum": ["linear", "radial"]],
                    "layer": index,
                    "document_id": docID,
                ], required: ["x0", "y0", "x1", "y1", "start_color"]),
            tool(
                "clear_selection",
                "Erases the active selection out of a layer: the selected pixels lose "
                    + "their color and become transparent, in proportion to the selection's "
                    + "coverage, so a feathered selection cuts a soft-edged hole. Only the "
                    + "one layer changes — whatever sits below it shows through. Errors "
                    + "when nothing is selected; make a selection with the select_* tools "
                    + "first.",
                [
                    "layer": index,
                    "document_id": docID,
                ]),
            tool(
                "rotate", "Rotates the whole document clockwise.",
                [
                    "degrees": ["type": "integer", "enum": [90, 180, 270, -90]],
                    "document_id": docID,
                ], required: ["degrees"]),
            tool(
                "flip", "Flips the whole document.",
                [
                    "axis": ["type": "string", "enum": ["horizontal", "vertical"]],
                    "document_id": docID,
                ], required: ["axis"]),
            tool(
                "crop",
                "Crops the document to a rectangle (canvas coordinates, origin top-left).",
                [
                    "x": ["type": "integer"], "y": ["type": "integer"],
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "document_id": docID,
                ], required: ["x", "y", "width", "height"]),
            tool(
                "image_size",
                "Scales the whole document to a new size (max 100 megapixels).",
                [
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "filter": [
                        "type": "string",
                        "enum": ["nearest", "bilinear", "catmull-rom", "lanczos3"],
                        "description": "Resampling filter, default lanczos3.",
                    ],
                    "document_id": docID,
                ], required: ["width", "height"]),
            tool(
                "canvas_size",
                "Resizes the canvas WITHOUT scaling the pixels; the anchor pins the existing "
                    + "content (like Photoshop's Canvas Size). Layers keep their pixels and "
                    + "can extend outside the canvas.",
                [
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "anchor": [
                        "type": "string",
                        "enum": [
                            "top-left", "top", "top-right", "left", "center", "right",
                            "bottom-left", "bottom", "bottom-right",
                        ],
                        "description": "Where the existing content is pinned; default center.",
                    ],
                    "document_id": docID,
                ], required: ["width", "height"]),
            tool("undo", "Undoes the most recent edit.", ["document_id": docID]),
            tool("redo", "Redoes the most recently undone edit.", ["document_id": docID]),
            tool(
                "save_copy",
                "Exports the flattened document to a file without changing the open document. "
                    + "Format comes from the extension unless given explicitly.",
                [
                    "path": ["type": "string"],
                    "format": [
                        "type": "string",
                        "enum": ["png", "jpeg", "tiff", "bmp", "gif", "webp"],
                    ],
                    "jpeg_quality": ["type": "integer", "minimum": 1, "maximum": 100],
                    "document_id": docID,
                ], required: ["path"]),
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog)
        return String(decoding: data, as: UTF8.self)
    }
}

/// C callback for RzAgentToolHandler: hops to the main thread, executes,
/// and hands the result back as a core-owned string.
private func agentToolTrampoline(
    _ context: UnsafeMutableRawPointer?,
    _ toolName: UnsafePointer<CChar>?,
    _ argumentsJSON: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let context = context, let toolName = toolName, let argumentsJSON = argumentsJSON
    else { return nil }
    let server = Unmanaged<AgentServer>.fromOpaque(context).takeUnretainedValue()
    let name = String(cString: toolName)
    let arguments = String(cString: argumentsJSON)
    let run = { server.execute(tool: name, argumentsJSON: arguments) }
    let result = Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
    return result.withCString { rz_agent_string_create($0) }
}
