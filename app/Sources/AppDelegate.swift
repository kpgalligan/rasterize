import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        // Gradient end colors (and brush colors) may carry alpha.
        NSColorPanel.shared.showsAlpha = true
    }

    // AppKit calls this only when the app is launched or reactivated with no
    // documents to open, so it can't race launch-time file opens the way a
    // check in applicationDidFinishLaunching does. There is no blank-canvas
    // "New" document; show the welcome window (design proposal 4) instead
    // of an untitled file.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        WelcomeWindowController.shared.show()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: AgentServer.enabledDefaultsKey) {
            startAgentServer()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentServer.shared.stop()
    }

    // MARK: - Agent server

    /// Tools > Allow Agent Connections: hosts an MCP endpoint on localhost
    /// so an external AI agent (goose, etc.) can drive the editor. Off by
    /// default; the preference persists across launches.
    @objc func toggleAgentServer(_ sender: Any?) {
        if AgentServer.shared.isRunning {
            AgentServer.shared.stop()
            UserDefaults.standard.set(false, forKey: AgentServer.enabledDefaultsKey)
        } else if startAgentServer() {
            UserDefaults.standard.set(true, forKey: AgentServer.enabledDefaultsKey)
        }
    }

    @discardableResult
    private func startAgentServer() -> Bool {
        do {
            try AgentServer.shared.start()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Start Agent Server"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    // MARK: - New from Clipboard

    /// Opens the frontmost pasteboard image as a new untitled document
    /// (Preview's ⌘N behavior). RasterImage.fromPasteboard normalizes the
    /// bitmap to PNG and routes it through the Rust core so the document
    /// behaves exactly like an opened file.
    @objc func newFromClipboard(_ sender: Any?) {
        guard let raster = RasterImage.fromPasteboard(),
              let document = ImageDocument.makeUntitled(with: raster)
        else {
            NSSound.beep()
            return
        }
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(newFromClipboard(_:)) {
            return NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        }
        if item.action == #selector(toggleAgentServer(_:)) {
            let server = AgentServer.shared
            item.state = server.isRunning ? .on : .off
            item.title =
                server.isRunning
                ? "Allow Agent Connections (127.0.0.1:\(server.port)/mcp)"
                : "Allow Agent Connections"
        }
        return true
    }

    // MARK: - Menu construction

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "MainMenu")
        mainMenu.addItem(submenuItem(appMenu()))
        mainMenu.addItem(submenuItem(fileMenu()))
        mainMenu.addItem(submenuItem(editMenu()))
        mainMenu.addItem(submenuItem(imageMenu()))
        mainMenu.addItem(submenuItem(layerMenu()))
        mainMenu.addItem(submenuItem(filtersMenu()))
        mainMenu.addItem(submenuItem(toolsMenu()))
        mainMenu.addItem(submenuItem(viewMenu()))

        let windowMenu = self.windowMenu()
        mainMenu.addItem(submenuItem(windowMenu))
        NSApp.windowsMenu = windowMenu

        let helpMenu = self.helpMenu()
        mainMenu.addItem(submenuItem(helpMenu))
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Rasterize")
        menu.addItem(
            item("About Rasterize", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Hide Rasterize", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(
            item(
                "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Rasterize", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New from Clipboard", #selector(newFromClipboard(_:)), "n"))
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))

        // AppKit auto-populates a submenu whose sole item's action is
        // clearRecentDocuments: as the Open Recent menu.
        let openRecent = NSMenu(title: "Open Recent")
        openRecent.addItem(
            item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentItem.submenu = openRecent
        menu.addItem(openRecentItem)

        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]))
        menu.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Export…", #selector(ImageDocument.exportDocument(_:)), "e"))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Copy", #selector(EditorViewController.copy(_:)), "c"))
        menu.addItem(
            item("Paste", Selector(("paste:")), "v"))
        menu.addItem(.separator())
        menu.addItem(item("Select All", #selector(EditorViewController.selectAll(_:)), "a"))
        menu.addItem(item("Deselect", #selector(EditorViewController.deselect(_:)), "d"))
        menu.addItem(
            item(
                "Invert Selection", #selector(EditorViewController.invertSelection(_:)), "i",
                [.command, .shift]))
        menu.addItem(
            item("Feather Selection…", #selector(EditorViewController.featherSelection(_:))))
        return menu
    }

    private func imageMenu() -> NSMenu {
        let menu = NSMenu(title: "Image")
        menu.addItem(
            item("Rotate 90° Clockwise", #selector(EditorViewController.rotateCW(_:)), "r"))
        menu.addItem(
            item(
                "Rotate 90° Counterclockwise", #selector(EditorViewController.rotateCCW(_:)), "r",
                [.command, .shift]))
        menu.addItem(item("Rotate 180°", #selector(EditorViewController.rotate180(_:))))
        menu.addItem(item("Flip Horizontal", #selector(EditorViewController.flipH(_:))))
        menu.addItem(item("Flip Vertical", #selector(EditorViewController.flipV(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item("Crop to Selection", #selector(EditorViewController.cropToSelection(_:)), "k"))
        menu.addItem(
            item("Image Size…", #selector(EditorViewController.resizeImage(_:)), "i", [.command, .option]))
        menu.addItem(
            item("Canvas Size…", #selector(EditorViewController.showCanvasSize(_:)), "c", [.command, .option]))
        return menu
    }

    private func layerMenu() -> NSMenu {
        let menu = NSMenu(title: "Layer")
        menu.addItem(
            item("New Layer", #selector(EditorViewController.newLayer(_:)), "n", [.command, .shift]))
        menu.addItem(item("Duplicate Layer", #selector(EditorViewController.duplicateLayer(_:)), "j"))
        menu.addItem(item("Delete Layer", #selector(EditorViewController.deleteLayer(_:))))
        menu.addItem(.separator())
        // Modal on-canvas session, not a tool: Return commits, Escape cancels.
        menu.addItem(item("Free Transform", #selector(EditorViewController.freeTransform(_:)), "t"))
        menu.addItem(.separator())
        menu.addItem(submenuItem(layerMaskMenu()))
        menu.addItem(.separator())
        menu.addItem(
            item("Merge Down", #selector(EditorViewController.mergeDown(_:)), "e", [.command, .shift]))
        menu.addItem(item("Flatten Image", #selector(EditorViewController.flattenImage(_:))))
        return menu
    }

    /// Layer > Mask. Enablement (and the Enable item's checkmark) comes from
    /// EditorViewController.validateUserInterfaceItem.
    private func layerMaskMenu() -> NSMenu {
        let menu = NSMenu(title: "Mask")

        let add = NSMenu(title: "Add Layer Mask")
        add.addItem(
            item("Reveal All", #selector(EditorViewController.addLayerMaskRevealAll(_:))))
        add.addItem(item("Hide All", #selector(EditorViewController.addLayerMaskHideAll(_:))))
        add.addItem(
            item(
                "From Selection", #selector(EditorViewController.addLayerMaskFromSelection(_:))))
        menu.addItem(submenuItem(add))

        menu.addItem(item("Delete Layer Mask", #selector(EditorViewController.deleteLayerMask(_:))))
        menu.addItem(item("Apply Layer Mask", #selector(EditorViewController.applyLayerMask(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item("Enable Layer Mask", #selector(EditorViewController.toggleLayerMaskEnabled(_:))))
        return menu
    }

    private func filtersMenu() -> NSMenu {
        let menu = NSMenu(title: "Filters")
        menu.addItem(
            item(
                "Adjust Colors…", #selector(EditorViewController.showAdjustments(_:)), "a",
                [.command, .option]))
        menu.addItem(item("Levels…", #selector(EditorViewController.showLevels(_:))))
        menu.addItem(item("Hue Rotate…", #selector(EditorViewController.showHueRotate(_:))))
        menu.addItem(item("Threshold…", #selector(EditorViewController.showThreshold(_:))))
        menu.addItem(item("Posterize…", #selector(EditorViewController.showPosterize(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Grayscale", #selector(EditorViewController.applyGrayscale(_:))))
        menu.addItem(item("Invert", #selector(EditorViewController.applyInvert(_:)), "i"))
        menu.addItem(item("Sepia", #selector(EditorViewController.applySepia(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Gaussian Blur…", #selector(EditorViewController.showBlur(_:))))
        menu.addItem(item("Sharpen", #selector(EditorViewController.applySharpen(_:))))
        menu.addItem(item("Pixelate…", #selector(EditorViewController.showPixelate(_:))))
        menu.addItem(item("Add Noise…", #selector(EditorViewController.showAddNoise(_:))))
        menu.addItem(item("Edge Detect", #selector(EditorViewController.applyEdgeDetect(_:))))
        menu.addItem(item("Emboss", #selector(EditorViewController.applyEmboss(_:))))
        return menu
    }

    private func toolsMenu() -> NSMenu {
        // Deliberately no key equivalents: the bare tool keys (v/b/e/t) are
        // handled in ImageCanvasView.keyDown so they never steal keystrokes
        // from text editing.
        let menu = NSMenu(title: "Tools")
        menu.addItem(item("Select Tool", #selector(EditorViewController.selectSelectTool(_:))))
        menu.addItem(
            item("Ellipse Select Tool", #selector(EditorViewController.selectEllipseTool(_:))))
        menu.addItem(item("Lasso Tool", #selector(EditorViewController.selectLassoTool(_:))))
        menu.addItem(item("Magic Wand Tool", #selector(EditorViewController.selectWandTool(_:))))
        menu.addItem(item("Move Tool", #selector(EditorViewController.selectMoveTool(_:))))
        menu.addItem(item("Brush Tool", #selector(EditorViewController.selectBrushTool(_:))))
        menu.addItem(item("Eraser Tool", #selector(EditorViewController.selectEraserTool(_:))))
        menu.addItem(item("Fill Tool", #selector(EditorViewController.selectFillTool(_:))))
        menu.addItem(
            item("Gradient Tool", #selector(EditorViewController.selectGradientTool(_:))))
        menu.addItem(item("Text Tool", #selector(EditorViewController.selectTextTool(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Allow Agent Connections", #selector(toggleAgentServer(_:))))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Zoom In", #selector(EditorViewController.zoomInAction(_:)), "+"))
        // Hidden alternate so plain ⌘= also zooms in.
        let zoomInEquals = item("Zoom In", #selector(EditorViewController.zoomInAction(_:)), "=")
        zoomInEquals.isHidden = true
        zoomInEquals.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInEquals)
        menu.addItem(item("Zoom Out", #selector(EditorViewController.zoomOutAction(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(EditorViewController.zoomActualAction(_:)), "0"))
        menu.addItem(item("Zoom to Fit", #selector(EditorViewController.zoomFitAction(_:)), "9"))
        menu.addItem(.separator())
        // Title toggles between Show/Hide Layers in validateUserInterfaceItem.
        menu.addItem(
            item(
                "Hide Layers", #selector(EditorViewController.toggleLayersPanel(_:)), "l",
                [.command, .option]))
        menu.addItem(
            item(
                "Assistant", #selector(EditorViewController.showAssistant(_:)), "a",
                [.command, .control]))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Rasterize Help", #selector(NSApplication.showHelp(_:))))
        return menu
    }
}
