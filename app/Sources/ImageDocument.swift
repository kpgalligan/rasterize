// The app module is named "Rasterize", so the integrator must set
// NSDocumentClass = "Rasterize.ImageDocument" on every CFBundleDocumentTypes
// entry in Info.plist.

import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by ImageDocument (object: the document) whenever `image` is
    /// replaced by an edit, undo, or redo.
    static let imageDocumentImageDidChange = Notification.Name("ImageDocumentImageDidChange")
}

final class ImageDocument: NSDocument {
    /// The current image. Set in read(from:ofType:); documents are never
    /// created blank.
    var image: RasterImage!

    /// Quality used for JPEG writes (Save/Save As and the last export choice).
    var jpegExportQuality: Int = 90

    private static let readableTypeIdentifiers: [String] = [
        "public.png",
        "public.jpeg",
        "com.adobe.photoshop-image",
        "public.tiff",
        "com.microsoft.bmp",
        "com.compuserve.gif",
        "org.webmproject.webp",
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
    static func makeUntitled(with image: RasterImage) -> ImageDocument {
        let document = ImageDocument()
        document.image = image
        document.fileType = "public.png"
        document.updateChangeCount(.changeDone)
        return document
    }

    override class var readableTypes: [String] { readableTypeIdentifiers }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        // GIF can be animated but the core keeps only the first frame, so an
        // in-place ⌘S would silently destroy the animation. Excluding it here
        // routes Save through the Save As panel (like PSD); choosing GIF there
        // is still allowed as a conscious decision.
        if saveOperation == .saveOperation {
            return Self.writableTypeIdentifiers.filter { $0 != "com.compuserve.gif" }
        }
        return Self.writableTypeIdentifiers
    }

    override func defaultDraftName() -> String { "Image" }

    override func fileNameExtension(
        forType typeName: String, saveOperation: NSDocument.SaveOperationType
    ) -> String? {
        if let format = ExportFormat.from(fileType: typeName) {
            return format.fileExtension
        }
        return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    // MARK: - Reading and writing

    override func read(from url: URL, ofType typeName: String) throws {
        image = try RasterImage.open(url: url)
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        // Revert replaces `image` via read(from:ofType:) without going through
        // applyEdit, so tell the editor UI explicitly.
        NotificationCenter.default.post(name: .imageDocumentImageDidChange, object: self)
    }

    override func write(to url: URL, ofType typeName: String) throws {
        guard let image = image else {
            throw RasterCoreError(message: "No image loaded.")
        }
        guard let format = ExportFormat.from(fileType: typeName) else {
            throw RasterCoreError(message: "Cannot write files of type \(typeName).")
        }
        try image.save(to: url, format: format.rzFormat, jpegQuality: jpegExportQuality)
    }

    // MARK: - Window controllers

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    // MARK: - Editing

    /// Applies `transform` to the current image. A nil result beeps and leaves
    /// the document untouched. Undo restores the exact prior handle.
    func applyEdit(_ actionName: String, _ transform: (RasterImage) -> RasterImage?) {
        guard let current = image, let updated = transform(current) else {
            NSSound.beep()
            return
        }
        undoManager?.registerUndo(withTarget: self) { document in
            document.restoreImage(current, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        image = updated
        NotificationCenter.default.post(name: .imageDocumentImageDidChange, object: self)
    }

    private func restoreImage(_ restored: RasterImage, actionName: String) {
        guard let current = image else { return }
        undoManager?.registerUndo(withTarget: self) { document in
            document.restoreImage(current, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        image = restored
        NotificationCenter.default.post(name: .imageDocumentImageDidChange, object: self)
    }

    // MARK: - Export

    /// "Save a copy" flow: does not change fileURL or clear the dirty state.
    @IBAction func exportDocument(_ sender: Any?) {
        guard let image = image, let window = windowForSheet else {
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
