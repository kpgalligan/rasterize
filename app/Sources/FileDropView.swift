import AppKit
import UniformTypeIdentifiers

/// Root view of the editor window: accepts image files dragged in from
/// Finder and opens each as a document, like dropping them on the Dock icon.
final class FileDropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FileDropView does not support NSCoder")
    }

    private func readableImageURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: options) as? [URL]
        else { return [] }
        let readable = ImageDocument.readableTypes.compactMap(UTType.init)
        return urls.filter { url in
            guard
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                    ?? UTType(filenameExtension: url.pathExtension)
            else { return false }
            return readable.contains { type.conforms(to: $0) }
        }
    }

    /// Dropping BOTH halves of a Live Photo — what Finder hands over when
    /// the pair is selected — must open ONE document, not two: either file
    /// opens the same Live Photo, so a clip whose still came along is
    /// dropped here.
    private func collapsingLivePhotoPairs(_ urls: [URL]) -> [URL] {
        let stillNames = Set(
            urls.filter { LivePhoto.stillExtensions.contains($0.pathExtension.lowercased()) }
                .map { $0.deletingPathExtension().path })
        return urls.filter { url in
            !(LivePhoto.videoExtensions.contains(url.pathExtension.lowercased())
                && stillNames.contains(url.deletingPathExtension().path))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        readableImageURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = collapsingLivePhotoPairs(readableImageURLs(from: sender))
        for url in urls {
            NSDocumentController.shared.openDocument(
                withContentsOf: url, display: true
            ) { _, _, error in
                if let error = error {
                    NSApp.presentError(error)
                }
            }
        }
        return !urls.isEmpty
    }
}
