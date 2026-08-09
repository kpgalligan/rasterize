import AppKit

final class EditorWindowController: NSWindowController {
    init(document: ImageDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentViewController = EditorViewController(document: document)
        window.backgroundColor = DS.chromeBackground
        window.titlebarAppearsTransparent = false

        // Initial content size: canvas size plus the editor chrome (layers
        // panel 304 + separator, toolbar 58, status bar 30), clamped to 80%
        // of the main screen's visible frame, minimum 560x360.
        var contentSize = document.doc?.canvasSize ?? NSSize(width: 480, height: 320)
        contentSize.width += DS.panelWidth + 1
        contentSize.height += DS.toolbarHeight + DS.statusBarHeight
        if let screen = NSScreen.main {
            let limit = screen.visibleFrame
            contentSize.width = min(contentSize.width, limit.width * 0.8)
            contentSize.height = min(contentSize.height, limit.height * 0.8)
        }
        contentSize.width = max(contentSize.width, 560)
        contentSize.height = max(contentSize.height, 360)
        window.setContentSize(contentSize)
        window.center()

        super.init(window: window)

        // Window title tracks the document name via the standard
        // synchronizeWindowTitleWithDocumentName behavior; only the subtitle
        // is managed here (and by the editor after edits). The design's
        // 38px two-line title bar is the native title + subtitle stack.
        if let doc = document.doc {
            window.subtitle = "\(doc.width) × \(doc.height) px"
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorWindowController does not support NSCoder")
    }

    /// Mirrors the editor's current tool into the toolbar pill. Display
    /// only: setting the selection does not re-dispatch the segment action.
    func reflectSelectedTool(_ tool: EditorTool) {
        (contentViewController as? EditorViewController)?.reflectSelectedTool(tool)
    }
}
