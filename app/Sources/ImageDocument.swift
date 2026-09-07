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

    /// The panel selection: a PRIMARY entry plus the others a set operation
    /// acts on. Deliberately NOT part of undo in itself — changing it
    /// neither dirties the document nor registers an undo step — but it IS
    /// captured by every undo registration, because undoing a Group Layers
    /// has to put the selection back on the layers that were grouped.
    /// Re-clamped whenever `doc` changes.
    ///
    /// Written through `setLayerSelection` / `selectLayer`
    /// (LayerSelection.swift) or through `activeLayerIndex` below.
    private(set) var layerSelection = LayerSelection.single(0)

    /// The layer that single-layer tools target — the selection's PRIMARY.
    ///
    /// It keeps its name and its exact old meaning so the ~120 places that
    /// ask "which layer am I working on?" need no change at all. Assigning
    /// it COLLAPSES the selection onto that one entry, which is what every
    /// existing write already meant (a click on a row, a new layer becoming
    /// active, `set_active_layer`); a genuine multi-selection is written
    /// with `setLayerSelection`.
    var activeLayerIndex: Int {
        get { layerSelection.primary }
        set { layerSelection = .single(newValue) }
    }

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

    /// Embed the document's ICC profile on export — Save/Save As, Export
    /// and the agent's save_copy alike. Per-document and not persisted, the
    /// same shape as `jpegExportQuality`; a format that cannot carry a
    /// profile ignores it (the save reports what was actually written).
    var embedColorProfile = true

    /// Drop EXIF / XMP / IPTC on export. Off — the default — re-splices the
    /// packets the file arrived with, EXIF orientation reset to 1: the
    /// camera rotation was baked into the pixels at open, so a preserved 6
    /// would double-rotate the picture in every viewer.
    var stripMetadata = false

    /// What the OPEN did to this document's colour: nothing, a conversion
    /// into the working space, or "kept, but not convertible from". It
    /// describes THE OPEN and is deliberately never updated by a later
    /// Assign or Convert — the document's profile name is the truth about
    /// the document, this is the truth about how it got here. A `.rz` never
    /// adopts, so it always reads `.unchanged`.
    private(set) var profileAdoption: RasterAdoptOutcome = .unchanged

    /// True when this document's source file was decoded by the PLATFORM
    /// (HEIC, a Live Photo still) rather than by the core, so its EXIF, XMP
    /// and IPTC were never read: the core's container walk covers JPEG and
    /// PNG only. It describes the OPEN, like `profileAdoption`, and matters
    /// on the way out — an export from such a document carries no capture
    /// data, and only this flag can tell that from a file that never had
    /// any. A clipboard or `.rz` document leaves it false: neither has a
    /// source container whose packets went unread.
    private(set) var metadataNotCaptured = false

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
    ///
    /// `profile` is the ICC bytes those pixel NUMBERS belong to, and this
    /// path follows the same colour rule as every other document-creating
    /// one (see `openDocument`): assign the profile the numbers came in,
    /// then adopt the working space exactly once. Without it a pasted
    /// Display P3 screenshot — the default on every current Mac — became a
    /// document holding P3 numbers labelled sRGB: over-saturated on screen,
    /// and every export propagated the wrong tag.
    static func makeUntitled(with image: RasterImage, profile: Data? = nil) -> ImageDocument? {
        guard var doc = RasterDocument.from(image: image) else { return nil }
        if let profile = profile, let tagged = doc.assigningProfile(profile) {
            doc = tagged
        }
        let document = ImageDocument()
        document.doc = doc
        document.adoptWorkingSpace()
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
        let opened = try Self.openDocument(at: url)
        doc = opened.doc
        metadataNotCaptured = opened.metadataNotCaptured
        if typeName != Self.nativeTypeIdentifier {
            // A .rz carries its own profile; converting it to the working
            // space would silently rewrite the user's document on every open.
            adoptWorkingSpace()
        }
        activeLayerIndex = max(doc.layerCount - 1, 0) // topmost
        refreshProjection()
    }

    /// Brings a freshly opened flat document into the colour working space,
    /// ONCE — the single conversion any opened file gets, whichever decoder
    /// produced its pixels. It runs before the document is shown, so it is
    /// part of the open and never an undo step.
    ///
    /// Internal, not private: `makeUntitled` is the fourth document-creating
    /// path and takes the same one conversion.
    func adoptWorkingSpace() {
        guard let current = doc else { return }
        let (adopted, outcome) = current.adoptingWorkingSpace(
            ColorSettings.workingSpace.profileData)
        profileAdoption = outcome
        if let adopted = adopted { doc = adopted }
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
    /// 4. COLOUR, on every one of those paths: the document is assigned the
    ///    profile its pixel NUMBERS actually belong to — the file's embedded
    ///    ICC bytes, the space the platform decoded into, or the built-in
    ///    sRGB for an untagged file — and nothing is converted here.
    ///    `read(from:ofType:)` then runs `adoptWorkingSpace()` exactly once,
    ///    which is the one and only conversion an open performs. The
    ///    CLIPBOARD is the fourth document-creating path and follows the
    ///    same two steps in `makeUntitled(with:profile:)`; pasting into an
    ///    open document instead converts the pixels into that document's
    ///    space, since a layer has no profile of its own.
    ///
    /// 5. METADATA comes from the core's own container walk and from
    ///    nowhere else. Paths 1 and 3 hand the core finished pixels, so a
    ///    HEIC's or a Live Photo still's EXIF, XMP and IPTC are never seen;
    ///    and the walk itself covers JPEG and PNG only, so a TIFF, WebP,
    ///    GIF, BMP or PSD on path 2 arrives without any either. A document
    ///    holding no packet is otherwise indistinguishable from a file that
    ///    had none, so `Opened.metadataNotCaptured` keeps the difference —
    ///    the core answers it for path 2 — and an export can say the capture
    ///    data never arrived instead of implying there was none.
    ///
    /// A file that none of the three can read reports the CORE's error, which
    /// names the file and the reason.
    private static func openDocument(at url: URL) throws -> Opened {
        let working = ColorSettings.workingSpace
        if let source = LivePhoto.locate(url), let payload = LivePhoto.inspect(source),
           let livePhoto = RasterDocument.from(
            livePhoto: payload, name: LivePhoto.layerName(for: source),
            space: working.cgSpace, profile: working.profileData)
        {
            // A video frame has no profile of its own, so it is decoded into
            // the working space and labelled with it; the adoption above
            // then finds them equal and does nothing.
            return Opened(doc: livePhoto, metadataNotCaptured: true)
        }
        // iPhone auxiliary images — depth, the portrait matte, the semantic
        // segmentation mattes — become named alpha channels on BOTH open
        // paths: "Most Compatible" mode writes JPEGs carrying the same
        // auxiliary images, and a JPEG is decoded by the core.
        do {
            let opened = try RasterDocument.open(url: url)
            return Opened(
                doc: AuxiliaryMattes.attaching(to: opened, from: url) ?? opened,
                // The CORE decides, not this side: it walks the container for
                // a JPEG and a PNG and reads its own .rz, and hands over
                // pixels alone for a TIFF, WebP, GIF, BMP or PSD — all of
                // which really can carry capture data. Asking it keeps that
                // policy in one place instead of restating it here.
                metadataNotCaptured: !RasterDocument.metadataWalked(at: url))
        } catch {
            guard let decoded = RasterImage.decoded(from: url),
                  let built = RasterDocument.from(image: decoded.image)
            else { throw error }
            var doc = built
            // The platform decoded into the source's OWN space, so these are
            // that profile's numbers; label them and let the adoption convert.
            if let profile = decoded.profile, let tagged = doc.assigningProfile(profile) {
                doc = tagged
            }
            if let dpi = decoded.dpi, let sized = doc.settingResolution(x: dpi.0, y: dpi.1) {
                doc = sized
            }
            // ImageIO gives us pixels, a profile and a dpi — no packets. A
            // HEIC really does carry EXIF, so this is a drop, not an absence.
            return Opened(
                doc: AuxiliaryMattes.attaching(to: doc, from: url) ?? doc,
                metadataNotCaptured: true)
        }
    }

    /// What an open produced: the document, and whether the file's capture
    /// data was left behind. Two ways that happens, and both set the flag:
    /// the platform decoders (ImageIO for a HEIC, AVFoundation for a Live
    /// Photo frame) hand over finished pixels and nothing else, and the
    /// core's own walk covers JPEG and PNG only, so a TIFF, WebP, GIF, BMP
    /// or PSD it decodes arrives without the EXIF, XMP or IPTC it may well
    /// have carried. The core answers the second half
    /// (`RasterDocument.metadataWalked`) rather than this side restating its
    /// container policy.
    private struct Opened {
        let doc: RasterDocument
        let metadataNotCaptured: Bool
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
        // The document-level save so the ICC profile, the EXIF/XMP/IPTC
        // packets and the print resolution ride along; the warm projection
        // goes in as the composite so ⌘S never re-flattens the layer stack.
        // What a format could not carry is reported, not fatal, and ⌘S says
        // nothing about it — the Export panel is where that conversation
        // belongs.
        _ = try doc.saveImage(
            flattened, to: url, format: format.rzFormat, jpegQuality: jpegExportQuality,
            embedProfile: embedColorProfile, stripMetadata: stripMetadata)
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
        let selection = layerSelection
        undoManager?.registerUndo(withTarget: self) { document in
            document.restoreDoc(current, selection: selection, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        doc = updated
        countEditChange(.changeDone)
        docDidChange()
    }

    /// Replaces the whole selection, clamped to the document. Like the
    /// single-layer `activeLayerIndex` write it retargets future edits only:
    /// no undo step, no dirty flag. The ONE setter, so the "always in range,
    /// always holds its primary" invariant lives in one place.
    func setLayerSelection(_ selection: LayerSelection) {
        layerSelection = selection.clamped(to: doc?.layerCount ?? 0)
    }

    /// Chains one pure per-entry op across the WHOLE selection as a single
    /// undo step — the panel header's blend mode and opacity, the lock
    /// items, visibility.
    ///
    /// For PROPERTY writes only: every index is resolved against the same
    /// stack, so an op that renumbers (group, delete, merge, reorder) must
    /// be ONE core call over the whole set instead — that is why the core
    /// exports `rz_doc_*_layers` rather than leaving the host to loop.
    ///
    /// A nil from `op` means "this entry did not change" — the core's purity
    /// rule, which a multi-selection hits constantly (three layers set to
    /// Multiply when one already is). The edit therefore carries on with the
    /// entries that DID change and fails only when none of them did, which
    /// is exactly when `applyEdit`'s beep is the right answer.
    func applyToSelectedLayers(
        _ actionName: String, _ op: @escaping (RasterDocument, Int) -> RasterDocument?
    ) {
        let indices = layerSelection.all
        applyEdit(actionName) { doc in
            var updated = doc
            var changed = false
            for idx in indices {
                if let next = op(updated, idx) {
                    updated = next
                    changed = true
                }
            }
            return changed ? updated : nil
        }
    }

    /// Opens or closes a GROUP's disclosure in the panel.
    ///
    /// A real document mutation, deliberately: `open` is persisted in the
    /// `.rz` layer record, and a field that saves without dirtying loses
    /// itself — open a document, toggle a disclosure, close it, and there is
    /// no save prompt and the state is gone, while any later edit would
    /// silently save it. So this counts a change like every other edit path.
    ///
    /// It registers NO undo: a disclosure triangle is not part of the
    /// picture, and an undo step for it would be noise the user never asked
    /// for. And it skips `refreshProjection()` — the picture did not change,
    /// only the row set — while still posting the change notification, which
    /// is what reloads the panel's rows.
    ///
    /// CLOSING a group re-points the selection at the rows that are still
    /// visible, through the same `visibleRow(for:)` the panel draws with. What
    /// the panel highlights and what a command acts on must be the same entry:
    /// a selected layer inside a group that then closes has no row of its own,
    /// the panel draws its GROUP's row selected instead, and leaving the
    /// selection on the hidden child meant Delete Layer, Merge Down and the
    /// footer buttons all acted on something other than the one row the panel
    /// said was selected. Remapping removes the mismatch rather than hiding
    /// it. Opening a group needs no remap: nothing stops being visible.
    func setGroupExpanded(_ idx: Int, _ open: Bool) {
        guard let current = doc, let updated = current.withLayerOpen(idx, open) else { return }
        doc = updated
        countEditChange(.changeDone)
        setLayerSelection(open ? layerSelection : layerSelection.mappedToVisibleRows(in: updated))
        NotificationCenter.default.post(
            name: .imageDocumentImageDidChange, object: self, userInfo: ["isLive": false])
    }

    /// Applies a flat-image operation to the ACTIVE layer's pixels as one
    /// undo step (filters and adjustments). Rewriting the pixels of a text
    /// layer invalidates its description, so this goes through
    /// applyRasterizingEdit.
    ///
    /// Deliberately SINGLE-layer even when several are selected: Photoshop
    /// filters the active layer only, and a filter fanned out across a
    /// selection would be one undo step holding several pictures the user
    /// never previewed. The set-aware entry point is
    /// `applyToSelectedLayers`, and it is for property writes.
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

    /// Undo/redo target. Restores the snapshot AND the SELECTION captured
    /// when the undo was registered, so undoing a structural layer op
    /// (delete, merge, reorder, group) does not silently retarget later
    /// edits — the whole set, not just the primary, because undoing a Group
    /// Layers has to put the selection back on the layers that were grouped.
    private func restoreDoc(
        _ restored: RasterDocument, selection: LayerSelection, actionName: String
    ) {
        guard let current = doc else { return }
        let now = layerSelection
        undoManager?.registerUndo(withTarget: self) { document in
            document.restoreDoc(current, selection: now, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        doc = restored
        layerSelection = selection
        if undoManager?.isRedoing == true {
            countEditChange(.changeRedone)
        } else {
            countEditChange(.changeUndone)
        }
        docDidChange() // prunes and clamps the selection as a safety net
    }

    private func docDidChange(isLive: Bool = false) {
        clampLayerSelection()
        refreshProjection()
        NotificationCenter.default.post(
            name: .imageDocumentImageDidChange, object: self, userInfo: ["isLive": isLive])
    }

    /// Prune-and-clamp, after every document change: an edit that removed
    /// entries (delete, merge, ungroup) leaves indices in the set that name
    /// nothing, or name something else. Pruning is what stops a stale index
    /// from silently retargeting the next set op.
    private func clampLayerSelection() {
        guard let doc = doc else { return }
        layerSelection = layerSelection.clamped(to: doc.layerCount)
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
            let selection = layerSelection
            undoManager?.registerUndo(withTarget: self) { document in
                document.restoreDoc(base, selection: selection, actionName: actionName)
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
    ///
    /// The pixels are decoded into THIS document's drawing space, so a P3
    /// image pasted into an sRGB document arrives as sRGB numbers and
    /// matches the region it was copied from. A layer carries no profile of
    /// its own — a document has exactly one — so this is the one conversion
    /// those pixels get, and CoreGraphics performs it.
    func pasteAsNewLayer() {
        guard let pasted = RasterImage.fromPasteboard(in: drawingSpace) else {
            NSSound.beep()
            return
        }
        let idx = activeLayerIndex
        let before = doc
        // Where the new layer lands is the CORE's answer, not `idx + 1`:
        // above a GROUP it goes above the whole subtree.
        let landing = before?.insertionIndex(above: idx) ?? idx + 1
        applyEdit("Paste Layer") { $0.addingImageLayer(above: idx, pasted, name: "Pasted Layer") }
        if doc !== before, let doc = doc {
            activeLayerIndex = min(landing, doc.layerCount - 1)
        }
    }

    // MARK: - Canvas-session safety

    /// Commits any in-progress canvas session — text entry, a Free Transform
    /// — so save/close/export paths never silently drop what the user can see
    /// on the canvas. The commits run through applyEdit, which also dirties
    /// the document, so close paths then show the standard unsaved-changes
    /// prompt.
    /// Internal, not private: the print operation (ImageDocument+Print.swift)
    /// is the same kind of read of the composite and does the same first.
    func commitPendingCanvasSessions() {
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
        // The document AND its composite are captured together, before the
        // panel opens: an agent edit landing while the panel is up must not
        // pair one snapshot's pixels with another's profile and packets.
        guard let source = doc, let image = projection ?? source.flattened(),
              let window = windowForSheet
        else {
            NSSound.beep()
            return
        }
        let initialFormat = ExportFormat.from(fileType: fileType ?? "") ?? .png

        let accessory = ExportAccessoryController()
        accessory.selectedFormat = initialFormat
        accessory.quality = jpegExportQuality
        accessory.embedProfile = embedColorProfile
        accessory.stripMetadata = stripMetadata

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
            let format = accessory.selectedFormat
            self.jpegExportQuality = accessory.quality
            self.embedColorProfile = accessory.embedProfile
            self.stripMetadata = accessory.stripMetadata
            do {
                let report = try source.saveImage(
                    image, to: url, format: format.rzFormat, jpegQuality: accessory.quality,
                    embedProfile: accessory.embedProfile,
                    stripMetadata: accessory.stripMetadata)
                // Not an error: a format that cannot carry a profile or a
                // packet still wrote the picture. Say so once, so the loss
                // is never silent.
                if let message = ExportCapabilities.droppedMessage(
                    source, report: report, format: format,
                    embedProfile: accessory.embedProfile,
                    stripMetadata: accessory.stripMetadata,
                    metadataNotCaptured: self.metadataNotCaptured)
                {
                    self.presentExportNotice(message)
                }
            } catch {
                self.presentError(error)
            }
        }
    }

    /// The informational half of an export: what the chosen format could
    /// not carry. Never a failure — the file was written.
    private func presentExportNotice(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Exported"
        alert.informativeText = message
        if let window = windowForSheet {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Printing

    /// NSDocument's own print selectors are delivered to the DOCUMENT, not
    /// to the editor, so they never reach `EditorViewController`'s
    /// validation switch: File > Print and Page Setup would stay enabled on
    /// a document with no image without this.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(printDocument(_:)), #selector(runPageLayout(_:)):
            return doc != nil
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
