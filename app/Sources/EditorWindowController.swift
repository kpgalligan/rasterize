import AppKit

private extension NSToolbarItem.Identifier {
    static let editorTools = NSToolbarItem.Identifier("EditorTools")
    static let editorToolSelect = NSToolbarItem.Identifier("rz.tool.select")
    static let editorToolMove = NSToolbarItem.Identifier("rz.tool.move")
    static let editorToolBrush = NSToolbarItem.Identifier("rz.tool.brush")
    static let editorToolEraser = NSToolbarItem.Identifier("rz.tool.eraser")
    static let editorToolText = NSToolbarItem.Identifier("rz.tool.text")
    static let editorZoomOut = NSToolbarItem.Identifier("EditorZoomOut")
    static let editorZoomIn = NSToolbarItem.Identifier("EditorZoomIn")
    static let editorZoomFit = NSToolbarItem.Identifier("EditorZoomFit")
    static let editorActualSize = NSToolbarItem.Identifier("EditorActualSize")
    static let editorCrop = NSToolbarItem.Identifier("EditorCrop")
}

final class EditorWindowController: NSWindowController, NSToolbarDelegate {
    private var toolGroup: NSToolbarItemGroup?

    init(document: ImageDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentViewController = EditorViewController(document: document)

        // Initial content size: canvas size plus the editor chrome (layers
        // panel 236 + separator, status bar 27), clamped to 80% of the main
        // screen's visible frame, minimum 480x320.
        var contentSize = document.doc?.canvasSize ?? NSSize(width: 480, height: 320)
        contentSize.width += 237
        contentSize.height += 27
        if let screen = NSScreen.main {
            let limit = screen.visibleFrame
            contentSize.width = min(contentSize.width, limit.width * 0.8)
            contentSize.height = min(contentSize.height, limit.height * 0.8)
        }
        contentSize.width = max(contentSize.width, 480)
        contentSize.height = max(contentSize.height, 320)
        window.setContentSize(contentSize)
        window.center()

        super.init(window: window)

        // Window title tracks the document name via the standard
        // synchronizeWindowTitleWithDocumentName behavior; only the subtitle
        // is managed here (and by the editor after edits).
        if let doc = document.doc {
            window.subtitle = "\(doc.width) × \(doc.height) px"
        }

        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorWindowController does not support NSCoder")
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .editorTools, .space,
            .editorZoomOut, .editorZoomIn, .editorZoomFit, .editorActualSize,
            .flexibleSpace, .editorCrop,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .editorTools:
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
            group.selectionMode = .selectOne
            group.label = "Tools"
            group.paletteLabel = "Tools"
            group.subitems = [
                makeToolItem(
                    .editorToolSelect, label: "Select", symbol: "cursorarrow",
                    action: #selector(EditorViewController.selectSelectTool(_:))),
                makeToolItem(
                    .editorToolMove, label: "Move",
                    symbol: "arrow.up.and.down.and.arrow.left.and.right",
                    fallbackSymbol: "hand.raised",
                    action: #selector(EditorViewController.selectMoveTool(_:))),
                makeToolItem(
                    .editorToolBrush, label: "Brush", symbol: "paintbrush.pointed",
                    action: #selector(EditorViewController.selectBrushTool(_:))),
                makeToolItem(
                    .editorToolEraser, label: "Eraser", symbol: "eraser",
                    action: #selector(EditorViewController.selectEraserTool(_:))),
                makeToolItem(
                    .editorToolText, label: "Text", symbol: "textformat",
                    action: #selector(EditorViewController.selectTextTool(_:))),
            ]
            group.selectedIndex = EditorTool.select.rawValue
            toolGroup = group
            return group
        case .editorZoomOut:
            return makeItem(
                itemIdentifier, label: "Zoom Out", symbol: "minus.magnifyingglass",
                action: #selector(EditorViewController.zoomOutAction(_:)))
        case .editorZoomIn:
            return makeItem(
                itemIdentifier, label: "Zoom In", symbol: "plus.magnifyingglass",
                action: #selector(EditorViewController.zoomInAction(_:)))
        case .editorZoomFit:
            return makeItem(
                itemIdentifier, label: "Zoom to Fit",
                symbol: "arrow.up.left.and.down.right.magnifyingglass",
                action: #selector(EditorViewController.zoomFitAction(_:)))
        case .editorActualSize:
            return makeItem(
                itemIdentifier, label: "Actual Size", symbol: "1.magnifyingglass",
                action: #selector(EditorViewController.zoomActualAction(_:)))
        case .editorCrop:
            return makeItem(
                itemIdentifier, label: "Crop", symbol: "crop",
                action: #selector(EditorViewController.cropToSelection(_:)))
        default:
            return nil
        }
    }

    private func makeItem(
        _ identifier: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.target = nil // resolve through the responder chain
        item.isBordered = true
        return item
    }

    private func makeToolItem(
        _ identifier: NSToolbarItem.Identifier, label: String, symbol: String,
        fallbackSymbol: String = "paintbrush", action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        // The segment falls back to its label if neither symbol resolves.
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: label)
        item.action = action
        item.target = nil // resolve through the responder chain
        return item
    }

    // MARK: - Tool selection display

    /// Mirrors the editor's current tool into the toolbar group. Display
    /// only: setting selectedIndex does not re-dispatch the segment action.
    func reflectSelectedTool(_ tool: EditorTool) {
        toolGroup?.selectedIndex = tool.rawValue
    }
}
