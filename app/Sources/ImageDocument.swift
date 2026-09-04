// The app module is named "Rasterize", so the integrator must set
// NSDocumentClass = "Rasterize.ImageDocument" on every CFBundleDocumentTypes
// entry in Info.plist.

import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by ImageDocument (object: the document) whenever `doc` is
    /// replaced by an edit, live edit, undo, or redo.
    static let imageDocumentImageDidChange = Notification.Name("ImageDocumentImageDidChange")
}

final class ImageDocument: NSDocument {
    /// The current layered document. Set in read(from:ofType:); documents are
    /// never created blank.
    var doc: RasterDocument!

    /// Flattened projection of `doc`, refreshed on every doc change: what the
    /// canvas draws, Copy copies, and flat-format writes encode.
    private(set) var projection: RasterImage?

    /// The layer that edits target (panel selection). Deliberately NOT part
    /// of undo: changing it neither dirties the document nor registers an
    /// undo step. Re-clamped whenever `doc` changes.
    var activeLayerIndex: Int = 0

    /// The editor's paint target, mirrored down so the ONE active-layer edit
    /// path can route a filter or an adjustment onto a single plane or an
    /// alpha channel (ImageDocument+Channels.swift). UI state: never
    /// persisted, never undoable, written only by
    /// EditorViewController.setPaintTarget.
    var planeEditTarget: PaintTarget = .layer

    /// Snapshot taken by beginLiveEdit, consumed by endLiveEdit.
    private var liveEditBase: RasterDocument?

    /// Quality used for JPEG writes (Save/Save As and the last export choice).
    var jpegExportQuality: Int = 90

    /// The native layered format (registered in Info.plist as .rz).
    static let nativeTypeIdentifier = "com.kgalligan.rasterize-document"

    private static let readableTypeIdentifiers: [String] = [
        nativeTypeIdentifier,
        "public.png",
        "public.jpeg",
        "com.adobe.photoshop-image",
        "public.tiff",
        "com.microsoft.bmp",
        "com.compuserve.gif",
        "org.webmproject.webp",
        // Decoded by the PLATFORM, not the core: HEIC/HEIF stills (the half
        // of a Live Photo the camera writes), and the QuickTime clip that is
        // its other half — opening either one opens the Live Photo.
        "public.heic",
        "public.heif",
        "com.apple.quicktime-movie",
    ]

    private static let writableTypeIdentifiers: [String] = [
        "public.png",
        "public.jpeg",
        "public.tiff",
        "com.microsoft.bmp",
        "com.compuserve.gif",
        "org.webmproject.webp",
    ]

    override init() {
        super.init()
        undoManager?.levelsOfUndo = 24
    }

    override class var autosavesInPlace: Bool { false }

    /// Creates an untitled, dirty document around in-memory pixels
    /// (File > New from Clipboard). Saving prompts for a location.
    static func makeUntitled(with image: RasterImage) -> ImageDocument? {
        guard let doc = RasterDocument.from(image: image) else { return nil }
        let document = ImageDocument()
        document.doc = doc
        document.activeLayerIndex = 0
        document.refreshProjection()
        document.fileType = "public.png"
        document.countEditChange(.changeDone)
        return document
    }

    override class var readableTypes: [String] { readableTypeIdentifiers }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        // Saving a multi-layer document to a flat format would silently
        // flatten it, so the native layered format goes FIRST: the Save As
        // panel's format popup defaults to the first entry, and in-place Save
        // additionally allows nothing else, routing other files through the
        // Save As panel where choosing a flat format is a conscious decision.
        if let doc = doc, doc.layerCount > 1 {
            if saveOperation == .saveOperation {
                return [Self.nativeTypeIdentifier]
            }
            return [Self.nativeTypeIdentifier] + Self.writableTypeIdentifiers
        }
        if saveOperation == .saveOperation {
            // GIF can be animated but the core keeps only the first frame, so an
            // in-place ⌘S would silently destroy the animation. Excluding it here
            // routes Save through the Save As panel (like PSD); choosing GIF there
            // is still allowed as a conscious decision.
            return Self.writableTypeIdentifiers.filter { $0 != "com.compuserve.gif" }
                + [Self.nativeTypeIdentifier]
        }
        return Self.writableTypeIdentifiers + [Self.nativeTypeIdentifier]
    }

    override func defaultDraftName() -> String { "Image" }

    override func fileNameExtension(
        forType typeName: String, saveOperation: NSDocument.SaveOperationType
    ) -> String? {
        if typeName == Self.nativeTypeIdentifier {
            return "rz"
        }
        if let format = ExportFormat.from(fileType: typeName) {
            return format.fileExtension
        }
        return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    // MARK: - Reading and writing

    override func read(from url: URL, ofType typeName: String) throws {
        doc = try Self.openDocument(at: url)
        activeLayerIndex = max(doc.layerCount - 1, 0) // topmost
        refreshProjection()
    }

    /// The app's open path, most specific first:
    ///
    /// 1. A LIVE PHOTO — either half of a still+clip pair, or a bare movie —
    ///    becomes one layer showing its key frame and carrying the
    ///    description Select Frame… re-renders from.
    /// 2. The core's own `rz_doc_open`, which transparently handles `.rz`,
    ///    layered PSD, and the flat formats (single "Background" layer).
    /// 3. Formats the core has no decoder for (HEIC, HEIF) fall back to the
    ///    platform's, as one flat layer.
    ///
    /// A file that none of the three can read reports the CORE's error, which
    /// names the file and the reason.
    private static func openDocument(at url: URL) throws -> RasterDocument {
        if let source = LivePhoto.locate(url), let payload = LivePhoto.inspect(source),
           let livePhoto = RasterDocument.from(
            livePhoto: payload, name: LivePhoto.layerName(for: source))
        {
            return livePhoto
        }
        // iPhone auxiliary images — depth, the portrait matte, the semantic
        // segmentation mattes — become named alpha channels on BOTH open
        // paths: "Most Compatible" mode writes JPEGs carrying the same
        // auxiliary images, and a JPEG is decoded by the core.
        do {
            let opened = try RasterDocument.open(url: url)
            return AuxiliaryMattes.attaching(to: opened, from: url) ?? opened
        } catch {
            guard let image = RasterImage.decoded(from: url),
                  let decoded = RasterDocument.from(image: image)
            else { throw error }
            return AuxiliaryMattes.attaching(to: decoded, from: url) ?? decoded
        }
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        // Revert replaces `doc` via read(from:ofType:) without going through
        // applyEdit, so tell the editor UI explicitly.
        NotificationCenter.default.post(
            name: .imageDocumentImageDidChange, object: self, userInfo: ["isLive": false])
    }

    override func write(to url: URL, ofType typeName: String) throws {
        guard let doc = doc else {
            throw RasterCoreError(message: "No image loaded.")
        }
        if typeName == Self.nativeTypeIdentifier {
            try doc.saveNative(to: url)
            return
        }
        guard let format = ExportFormat.from(fileType: typeName) else {
            throw RasterCoreError(message: "Cannot write files of type \(typeName).")
        }
        guard let flattened = projection ?? doc.flattened() else {
            throw RasterCoreError(message: "Could not flatten the document.")
        }
        try flattened.save(to: url, format: format.rzFormat, jpegQuality: jpegExportQuality)
    }

    // MARK: - Window controllers

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    // MARK: - Change counting

    /// NSDocument's automatic undo-based change counting is unreliable
    /// here: whether the DidCloseUndoGroup/DidUndo/DidRedo counting fires
    /// depends on how the run loop is being driven (real UI events versus
    /// the agent server's dispatched-to-main tool calls), which double- or
    /// zero-counts edits. So this class counts every edit explicitly at
    /// the applyEdit/restoreDoc/endLiveEdit sites, and this override drops
    /// the automatic done/undone/redone calls. Clearing (save) and other
    /// change types pass through untouched.
    private var allowEditChangeCount = false

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        switch change {
        case .changeDone, .changeUndone, .changeRedone:
            guard allowEditChangeCount else { return }
        default:
            break
        }
        super.updateChangeCount(change)
    }

    /// The explicit counting entry used by this class's edit paths.
    func countEditChange(_ change: NSDocument.ChangeType) {
        allowEditChangeCount = true
        updateChangeCount(change)
        allowEditChangeCount = false
    }

    // MARK: - Editing

    /// Applies `transform` to the current document. A nil result beeps and
    /// leaves the document untouched. Undo restores the exact prior handle
    /// (whole-document snapshots stay cheap: handles are copy-on-write).
    func applyEdit(_ actionName: String, _ transform: (RasterDocument) -> RasterDocument?) {
        guard let current = doc, let updated = transform(current) else {
            NSSound.beep()
            return
        }
        let index = activeLayerIndex
        undoManager?.registerUndo(withTarget: self) { document in
            document.restoreDoc(current, activeIndex: index, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        doc = updated
        countEditChange(.changeDone)
        docDidChange()
    }

    /// Applies a flat-image operation to the ACTIVE layer's pixels as one
    /// undo step (filters and adjustments). Rewriting the pixels of a text
    /// layer invalidates its description, so this goes through
    /// applyRasterizingEdit.
    func applyToActiveLayer(_ actionName: String, _ op: (RasterImage) -> RasterImage?) {
        // A colour plane or an alpha channel is targeted: the same op runs
        // on that plane alone (ImageDocument+Channels.swift).
        if applyToTargetPlane(actionName, op) { return }
        let idx = activeLayerIndex
        applyRasterizingEdit(actionName, layer: idx) { doc in
            guard let layer = doc.layerImage(idx), let filtered = op(layer) else { return nil }
            return doc.withLayerPixels(idx, filtered)
        }
    }

    /// applyEdit for an edit that rewrites a layer's pixels DESTRUCTIVELY —
    /// painting, filling, filtering, adjusting. A plain raster layer goes
    /// straight through. On a DESCRIBED layer — text, a Live Photo frame —
    /// the raster would stop being the rendering of its description, so the
    /// user is asked first: Cancel abandons the edit entirely, Rasterize
    /// drops the description inside the SAME edit, keeping it one undo step.
    ///
    /// Whole-document geometry (rotate, flip, image/canvas size) and a plain
    /// affine Free Transform deliberately do NOT come through here: they
    /// COMPOSE into a described layer's description (DescribedLayer.swift)
    /// and the layer re-renders through it, so the description survives.
    /// The perspective path and a description that cannot render right now
    /// still do.
    ///
    /// USER-initiated edits only — it can put up a modal alert, so anything
    /// running on the agent's dispatched-to-main path must use applyEdit and
    /// decide about the metadata itself.
    func applyRasterizingEdit(
        _ actionName: String, layer idx: Int, _ transform: (RasterDocument) -> RasterDocument?
    ) {
        guard let current = doc else {
            NSSound.beep()
            return
        }
        let described = layerDescribesSource(idx)
        guard confirmRasterize(layer: idx) else { return }
        applyEdit(actionName) { doc in
            guard let updated = transform(doc) else { return nil }
            guard described else { return updated }
            return updated.withLayerMeta(idx, nil) ?? updated
        }
    }

    /// True when layer `idx`'s pixels are the RENDERING of a description —
    /// a text layer's string, a shape's geometry, a live photo layer's frame
    /// — which is exactly what a destructive edit would contradict. Judged
    /// by the kind the meta CLAIMS (`LayerDescription.claimedKind`), not by
    /// whether this build can decode it: a description at a payload version
    /// this build does not know still describes the pixels, and leaving it
    /// in place through a paint would hand the next build that understands
    /// it a description of pixels that no longer exist. (An adjustment
    /// layer has no pixels of its own to contradict, so it is deliberately
    /// not one of these.) The paths that cannot use applyRasterizingEdit ask
    /// this: the live-edit brush then clears the metadata itself, and the
    /// Free Transform commit composes into the description or prompts.
    func layerDescribesSource(_ idx: Int) -> Bool {
        guard let doc = doc else { return false }
        return LayerDescription.claimedKind(of: doc.layerMeta(idx)) != nil
    }

    /// Layer `idx`'s description (text, shape or Live Photo), for the
    /// feature extensions; nil for a plain raster layer.
    func layerDescription(_ idx: Int) -> LayerDescription? {
        doc?.layerDescription(idx)
    }

    /// Asks — once, app-modally — whether a destructive edit may drop layer
    /// `idx`'s description, in the words of whichever kind it is. True means
    /// the edit may proceed: either the layer carries no description, or the
    /// user confirmed. `reason` adds a line saying why THIS edit has to
    /// rasterize when that is not obvious (`unrenderableReason`).
    func confirmRasterize(layer idx: Int, reason: String? = nil) -> Bool {
        guard let doc = doc else { return true }
        let name = doc.layerInfo(idx)?.name ?? "this layer"
        // By the claimed kind, like layerDescribesSource: a description this
        // build cannot decode is still dropped, and still asked about.
        switch LayerDescription.claimedKind(of: doc.layerMeta(idx)) {
        case .text?:
            return TextLayer.confirmRasterize(layerName: name, reason: reason)
        case .livePhoto?:
            return LivePhoto.confirmRasterize(layerName: name, reason: reason)
        case .shape?:
            return ShapeLayer.confirmRasterize(layerName: name, reason: reason)
        case nil:
            return true
        }
    }

    /// Why a Free Transform on layer `idx` has to rasterize instead of
    /// composing into its description — because the description cannot
    /// render right now (a text family not installed here, a Live Photo
    /// whose source will not decode) or because the pixels are not its
    /// rendering any more (`RasterDocument.describedRasterIsStale`); nil
    /// for a plain layer, a shape that could render, or a description that
    /// could render over its own raster.
    func unrenderableReason(layer idx: Int) -> String? {
        guard let doc = doc, let description = layerDescription(idx) else { return nil }
        guard !description.isRenderable else {
            guard doc.describedRasterIsStale(idx) else { return nil }
            return "It has to rasterize because its pixels are no longer the rendering of its "
                + "description — an earlier version's Image Size resampled them while the "
                + "description kept its original size — so composing the transform into the "
                + "description would re-render the layer at a size you never saw."
        }
        switch description {
        case let .text(payload):
            return "It has to rasterize because its font family “\(payload.font)” is not "
                + "installed here: re-rendering it through the transform would substitute a "
                + "face."
        case .shape:
            return nil
        case let .livePhoto(payload):
            return "It has to rasterize because the source its frame is drawn from cannot "
                + "be decoded right now (\(payload.renderSource) — moved, deleted or "
                + "damaged), so the frame cannot be re-rendered."
        }
    }

    /// Undo/redo target. Restores the snapshot AND the active-layer index
    /// captured when the undo was registered, so undoing a structural layer
    /// op (delete, merge, reorder) does not silently retarget later edits.
    private func restoreDoc(_ restored: RasterDocument, activeIndex: Int, actionName: String) {
        guard let current = doc else { return }
        let index = activeLayerIndex
        undoManager?.registerUndo(withTarget: self) { document in
            document.restoreDoc(current, activeIndex: index, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        doc = restored
        activeLayerIndex = activeIndex
        if undoManager?.isRedoing == true {
            countEditChange(.changeRedone)
        } else {
            countEditChange(.changeUndone)
        }
        docDidChange() // clamps activeLayerIndex as a safety net
    }

    private func docDidChange(isLive: Bool = false) {
        clampActiveLayerIndex()
        refreshProjection()
        NotificationCenter.default.post(
            name: .imageDocumentImageDidChange, object: self, userInfo: ["isLive": isLive])
    }

    private func clampActiveLayerIndex() {
        guard let doc = doc else { return }
        activeLayerIndex = min(max(activeLayerIndex, 0), max(doc.layerCount - 1, 0))
    }

    private func refreshProjection() {
        projection = doc?.flattened()
    }

    // MARK: - Live edits (Move drags, opacity slider scrubs)

    /// True while a live-edit gesture is in progress (between beginLiveEdit
    /// and endLiveEdit). The layers panel uses this — together with the
    /// "isLive" userInfo on imageDocumentImageDidChange — to defer expensive
    /// refreshes until the gesture ends.
    var isLiveEditing: Bool { liveEditBase != nil }

    /// Snapshots the current doc handle. The following updateLiveEdit calls
    /// swap the document without touching the undo stack; endLiveEdit turns
    /// the whole gesture into a single undo step.
    func beginLiveEdit() {
        guard liveEditBase == nil else { return }
        liveEditBase = doc
    }

    /// Swaps in `new` and refreshes the UI with NO undo registration. The
    /// change notification carries ["isLive": true].
    func updateLiveEdit(_ new: RasterDocument) {
        doc = new
        docDidChange(isLive: true)
    }

    /// Registers one undo step from the beginLiveEdit snapshot to the current
    /// doc (none if the doc never changed — same handle), then posts one
    /// final ["isLive": false] change notification so listeners that skip
    /// live updates refresh exactly once per gesture.
    func endLiveEdit(_ actionName: String) {
        guard let base = liveEditBase else { return }
        liveEditBase = nil
        if base !== doc {
            let index = activeLayerIndex
            undoManager?.registerUndo(withTarget: self) { document in
                document.restoreDoc(base, activeIndex: index, actionName: actionName)
            }
            undoManager?.setActionName(actionName)
            countEditChange(.changeDone)
        }
        NotificationCenter.default.post(
            name: .imageDocumentImageDidChange, object: self, userInfo: ["isLive": false])
    }

    // MARK: - Pasteboard

    /// Pastes the frontmost pasteboard image as a new layer above the active
    /// one and selects it.
    func pasteAsNewLayer() {
        guard let pasted = RasterImage.fromPasteboard() else {
            NSSound.beep()
            return
        }
        let idx = activeLayerIndex
        let before = doc
        applyEdit("Paste Layer") { $0.addingImageLayer(above: idx, pasted, name: "Pasted Layer") }
        if doc !== before, let doc = doc {
            activeLayerIndex = min(idx + 1, doc.layerCount - 1)
        }
    }

    // MARK: - Canvas-session safety

    /// Commits any in-progress canvas session — text entry, a Free Transform
    /// — so save/close/export paths never silently drop what the user can see
    /// on the canvas. The commits run through applyEdit, which also dirties
    /// the document, so close paths then show the standard unsaved-changes
    /// prompt.
    private func commitPendingCanvasSessions() {
        for controller in windowControllers {
            (controller.contentViewController as? EditorViewController)?
                .commitPendingSessions()
        }
    }

    override func save(_ sender: Any?) {
        commitPendingCanvasSessions()
        // If the file's current format is not allowed for an in-place Save
        // (flat formats on a multi-layer document, GIF), reroute through the
        // Save As panel explicitly. Relying on NSDocument's own fallback is
        // not safe here: its panel preselects the current fileType or the
        // first writable type, which could silently flatten the document.
        if fileURL != nil, let fileType = fileType,
            !writableTypes(for: .saveOperation).contains(fileType)
        {
            runModalSavePanel(for: .saveAsOperation, delegate: nil, didSave: nil, contextInfo: nil)
            return
        }
        super.save(sender)
    }

    override func save(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Last line of defense against silent flattening: Save/Save As of a
        // multi-layer document to a flat format must be confirmed. Save To
        // ("save a copy") and Export never retarget the document, so they
        // stay silent.
        guard let doc = doc, doc.layerCount > 1, typeName != Self.nativeTypeIdentifier,
            saveOperation != .saveToOperation
        else {
            super.save(
                to: url, ofType: typeName, for: saveOperation,
                completionHandler: completionHandler)
            return
        }
        let formatName = ExportFormat.from(fileType: typeName)?.displayName ?? typeName
        let alert = NSAlert()
        alert.messageText = "Save Flattened?"
        alert.informativeText =
            "\(formatName) cannot store the document's \(doc.layerCount) layers; only the "
            + "flattened image will be saved. To keep the layers, choose the Rasterize "
            + "Document format instead."
        alert.addButton(withTitle: "Save Flattened")
        alert.addButton(withTitle: "Cancel")
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                super.save(
                    to: url, ofType: typeName, for: saveOperation,
                    completionHandler: completionHandler)
            } else {
                completionHandler(CocoaError(.userCancelled))
            }
        }
        if let window = windowForSheet {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    override func saveAs(_ sender: Any?) {
        commitPendingCanvasSessions()
        super.saveAs(sender)
    }

    override func canClose(
        withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        commitPendingCanvasSessions()
        super.canClose(
            withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    // MARK: - Export

    /// "Save a copy" flow: does not change fileURL or clear the dirty state.
    /// Exports the flattened projection.
    @IBAction func exportDocument(_ sender: Any?) {
        commitPendingCanvasSessions()
        guard let image = projection ?? doc?.flattened(), let window = windowForSheet else {
            NSSound.beep()
            return
        }
        let initialFormat = ExportFormat.from(fileType: fileType ?? "") ?? .png

        let accessory = ExportAccessoryController()
        accessory.selectedFormat = initialFormat
        accessory.quality = jpegExportQuality

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [initialFormat.utType]
        panel.nameFieldStringValue =
            ((displayName ?? "Image") as NSString).deletingPathExtension + "-export"
        panel.accessoryView = accessory.view
        accessory.onFormatChange = { [weak panel] format in
            // The panel keeps the basename and swaps the extension.
            panel?.allowedContentTypes = [format.utType]
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self = self, let url = panel.url else { return }
            self.jpegExportQuality = accessory.quality
            do {
                try image.save(
                    to: url,
                    format: accessory.selectedFormat.rzFormat,
                    jpegQuality: accessory.quality)
            } catch {
                self.presentError(error)
            }
        }
    }
}
