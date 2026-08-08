import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
    }

    // AppKit calls this only when the app is launched or reactivated with no
    // documents to open, so it can't race launch-time file opens the way a
    // check in applicationDidFinishLaunching does. There is no blank-canvas
    // "New" document, so offer the open panel instead of an untitled file.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - New from Clipboard

    /// Opens the frontmost pasteboard image as a new untitled document
    /// (Preview's ⌘N behavior). The bitmap is normalized to PNG and routed
    /// through the Rust core so the document behaves exactly like an opened
    /// file.
    @objc func newFromClipboard(_ sender: Any?) {
        guard let pasted = NSImage(pasteboard: .general),
              let tiff = pasted.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            NSSound.beep()
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rasterize-clipboard-\(ProcessInfo.processInfo.globallyUniqueString).png")
        do {
            try png.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let raster = try RasterImage.open(url: tempURL)
            let document = ImageDocument.makeUntitled(with: raster)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            NSApp.presentError(error)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(newFromClipboard(_:)) {
            return NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
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
        mainMenu.addItem(submenuItem(filtersMenu()))
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
        menu.addItem(.separator())
        menu.addItem(item("Select All", #selector(EditorViewController.selectAll(_:)), "a"))
        menu.addItem(item("Deselect", #selector(EditorViewController.deselect(_:)), "d"))
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
            item("Resize…", #selector(EditorViewController.resizeImage(_:)), "i", [.command, .option]))
        return menu
    }

    private func filtersMenu() -> NSMenu {
        let menu = NSMenu(title: "Filters")
        menu.addItem(
            item(
                "Adjust Colors…", #selector(EditorViewController.showAdjustments(_:)), "a",
                [.command, .option]))
        menu.addItem(item("Grayscale", #selector(EditorViewController.applyGrayscale(_:))))
        menu.addItem(item("Invert", #selector(EditorViewController.applyInvert(_:)), "i"))
        menu.addItem(item("Sepia", #selector(EditorViewController.applySepia(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Gaussian Blur…", #selector(EditorViewController.showBlur(_:))))
        menu.addItem(item("Sharpen", #selector(EditorViewController.applySharpen(_:))))
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
