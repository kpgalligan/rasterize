import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
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
    /// (Preview's ⌘N behavior). `RasterImage.fromPasteboard` decodes the
    /// bitmap into its own colour space and reports the profile those
    /// numbers belong to, so the document is tagged and then adopted into
    /// the working space exactly as an opened file is.
    @objc func newFromClipboard(_ sender: Any?) {
        guard let pasted = RasterImage.fromPasteboard(),
              let document = ImageDocument.makeUntitled(
                with: pasted.image, profile: pasted.profile)
        else {
            NSSound.beep()
            return
        }
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    // MARK: - Working space

    /// Image > Mode > Working Space ▸ — the profile FUTURE opens are
    /// converted into. The sender's tag indexes `WorkingSpace.allCases`,
    /// the layer-style menu's idiom, so the menu needs no parallel list to
    /// stay in step with the enum.
    ///
    /// It lives HERE and not on `EditorViewController` — where the rest of
    /// Image > Mode lives — because it is an app-wide preference that by
    /// design touches no document: it has to be settable at the Welcome
    /// window, before the first open, which is exactly the moment a
    /// document-scoped responder does not exist. Being the only responder
    /// that implements it also keeps it a single implementation, whether or
    /// not a document window is key.
    @objc func setWorkingSpace(_ sender: Any?) {
        let spaces = WorkingSpace.allCases
        let tag = (sender as? NSMenuItem)?.tag ?? -1
        guard spaces.indices.contains(tag) else {
            NSSound.beep()
            return
        }
        ColorSettings.workingSpace = spaces[tag]
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(newFromClipboard(_:)) {
            return NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        }
        if item.action == #selector(setWorkingSpace(_:)) {
            // Radio marks against the stored preference, so the menu shows
            // which space new opens use — with or without a document.
            let spaces = WorkingSpace.allCases
            item.state = spaces.indices.contains(item.tag)
                && spaces[item.tag] == ColorSettings.workingSpace ? .on : .off
            return true
        }
        // The four File ▸ Automate items and the palette, all of which must
        // work with no document open — which is why they are here and not in
        // the editor's table.
        if item.action == #selector(toggleActionRecording(_:)) {
            item.title = ActionRecorder.shared.isRecording ? "Stop Recording" : "Start Recording"
            return true
        }
        if item.action == #selector(playLastAction(_:)) {
            // The SUMMARY only. This runs on every File-menu update, and
            // decoding the steps of the last recorded paint session to put a
            // name in a menu item was the single worst stall in the feature
            // (Action.decodeSummary). The steps are read by the command
            // itself, once, when it is actually chosen.
            let last = ActionLibrary.mostRecentlyModified()
            item.title = last.map { "Play “\($0.summary.name)”" } ?? "Play Last Action"
            // The SAME lookup the command itself uses, and the same one the
            // Actions window's Play button uses: `currentDocument` is nil
            // whenever a non-document window is main — including the Actions
            // window this item is meant to be used beside — and this item
            // used to grey itself out with a document plainly open behind it.
            return last != nil && ActionPlayer.frontDocument() != nil
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

    // MARK: - Automate (File ▸ Automate, Tools ▸ Command Palette…)

    /// File ▸ Automate ▸ Actions… — the app-wide library window.
    @objc func showActions(_ sender: Any?) {
        ActionsWindowController.shared.show()
    }

    /// File ▸ Automate ▸ Start/Stop Recording, and the Actions window's own
    /// Record and Stop buttons, which target this selector through the
    /// responder chain. Stopping opens the library window, which is where the
    /// recording is named and kept.
    ///
    /// Starting DISCARDS a stopped-but-unsaved recording, so it asks first:
    /// those steps live only in memory, no file holds them, and no undo
    /// covers Application Support. The window lists them as "Unsaved
    /// recording — N steps" and its Save Recording button is the only way to
    /// keep them, so the alert points at exactly that.
    @objc func toggleActionRecording(_ sender: Any?) {
        let recorder = ActionRecorder.shared
        if recorder.isRecording {
            recorder.stop()
        } else {
            guard confirmDiscardingRecording() else { return }
            recorder.start()
        }
        ActionsWindowController.shared.show()
    }

    /// True when recording may start: nothing is pending, or the user said to
    /// throw it away.
    private func confirmDiscardingRecording() -> Bool {
        let recorder = ActionRecorder.shared
        guard recorder.hasUnsavedRecording else { return true }
        let count = recorder.steps.count
        let alert = NSAlert()
        alert.messageText =
            "Discard the unsaved recording of \(count) step\(count == 1 ? "" : "s")?"
        alert.informativeText =
            "Starting a new recording replaces it. To keep it, cancel and use Save Recording "
            + "in the Actions window."
        alert.addButton(withTitle: "Discard and Record")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// File ▸ Automate ▸ Play "<name>" — the most recently modified action,
    /// on the frontmost document, as one undo step.
    ///
    /// The steps are read HERE, by the file the menu item named, and not by
    /// name: two files may claim one display name only through a hand-edit,
    /// and the item must play the one it was titled after. A file whose
    /// header read cleanly can still fail to decode — a malformed symbol, a
    /// non-finite number — and that reason is shown rather than beeped away,
    /// since it names the step and the argument that need fixing.
    @objc func playLastAction(_ sender: Any?) {
        guard let last = ActionLibrary.mostRecentlyModified(),
              let document = ActionPlayer.frontDocument()
        else {
            NSSound.beep()
            return
        }
        let action: Action
        switch ActionLibrary.action(at: last.url) {
        case .ok(let decoded):
            action = decoded
        case .broken(let file, let reason):
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "“\(last.summary.name)” could not be read"
            alert.informativeText = "\(file): \(reason)"
            alert.runModal()
            return
        }
        let report = ActionPlayer.run(
            action, on: document, stopOnError: nil, progress: ActionRunProgress())
        ActionPlayer.notePlayed(action, report, on: document)
        if !report.ok { NSSound.beep() }
    }

    /// File ▸ Automate ▸ Batch…
    @objc func showBatch(_ sender: Any?) {
        BatchWindowController.present()
    }

    /// Tools ▸ Command Palette… (⇧⌘K).
    @objc func showCommandPalette(_ sender: Any?) {
        CommandPaletteWindowController.shared.show()
    }

    // MARK: - Menu construction

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "MainMenu")
        mainMenu.addItem(submenuItem(appMenu()))
        mainMenu.addItem(submenuItem(fileMenu()))
        mainMenu.addItem(submenuItem(editMenu()))
        mainMenu.addItem(submenuItem(imageMenu()))
        mainMenu.addItem(submenuItem(layerMenu()))
        mainMenu.addItem(submenuItem(selectMenu()))
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

        // File ▸ Automate — Actions and Batch. All four live on AppDelegate
        // rather than the editor because `EditorViewController
        // .validateUserInterfaceItem` returns false at its first line with no
        // document open, and every one of these must work with none.
        let automate = NSMenu(title: "Automate")
        automate.addItem(
            item("Actions…", #selector(showActions(_:)), "t", [.control, .command]))
        // The title flips to Stop Recording, the idiom toggleAgentServer uses.
        automate.addItem(item("Start Recording", #selector(toggleActionRecording(_:))))
        // …and this one to Play "<name>".
        automate.addItem(item("Play Last Action", #selector(playLastAction(_:))))
        automate.addItem(.separator())
        automate.addItem(item("Batch…", #selector(showBatch(_:))))
        let automateItem = NSMenuItem(title: "Automate", action: nil, keyEquivalent: "")
        automateItem.submenu = automate
        menu.addItem(automateItem)

        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]))
        menu.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Export…", #selector(ImageDocument.exportDocument(_:)), "e"))
        menu.addItem(.separator())
        // Both selectors are NSDocument's own and reach the document through
        // the responder chain; ImageDocument.validateUserInterfaceItem gates
        // them on there being an image.
        menu.addItem(
            item(
                "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p",
                [.command, .shift]))
        menu.addItem(item("Print…", #selector(NSDocument.printDocument(_:)), "p"))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(EditorViewController.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(EditorViewController.copy(_:)), "c"))
        // Photoshop's pair and its shortcut: Copy takes the active layer,
        // Copy Merged the flattened composite.
        menu.addItem(
            item(
                "Copy Merged", #selector(EditorViewController.copyMerged(_:)), "c",
                [.command, .shift]))
        menu.addItem(
            item("Paste", Selector(("paste:")), "v"))
        // Bare ⌫: U+0008 (NSBackspaceCharacter) is what AppKit matches the
        // Delete key against and what it draws as ⌫ (U+007F is forward
        // delete, ⌦). A modifier-less key equivalent is resolved ahead of the
        // first responder, so EditorViewController.validateUserInterfaceItem
        // keeps this item disabled unless there is something to clear and no
        // text is being edited — otherwise it would swallow every Delete.
        menu.addItem(
            item("Clear", #selector(EditorViewController.clearSelection(_:)), "\u{8}", []))
        menu.addItem(.separator())
        // Photoshop hangs this off Edit > Fill…; there is no Fill dialog in
        // this build (the paint bucket is a TOOL), so it takes Fill's slot
        // directly, after Clear.
        menu.addItem(
            item(
                "Content-Aware Fill…",
                #selector(EditorViewController.contentAwareFill(_:))))
        return menu
    }

    /// Top-level Select menu (Photoshop's slot: after Layer, before Filters).
    /// Enablement comes from EditorViewController.validateUserInterfaceItem,
    /// keyed on the action selectors — so these items validate identically
    /// wherever they live.
    private func selectMenu() -> NSMenu {
        let menu = NSMenu(title: "Select")
        menu.addItem(item("Select All", #selector(EditorViewController.selectAll(_:)), "a"))
        menu.addItem(item("Deselect", #selector(EditorViewController.deselect(_:)), "d"))
        menu.addItem(
            item(
                "Invert Selection", #selector(EditorViewController.invertSelection(_:)), "i",
                [.command, .shift]))
        menu.addItem(.separator())
        // Vision segmentation; needs no selection to start from, so it sits
        // with Select All rather than with the modify-the-selection block.
        menu.addItem(
            item("Select Subject", #selector(EditorViewController.selectSubject(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item("Feather Selection…", #selector(EditorViewController.featherSelection(_:))))
        menu.addItem(
            item("Grow Selection…", #selector(EditorViewController.growSelection(_:))))
        menu.addItem(
            item("Shrink Selection…", #selector(EditorViewController.shrinkSelection(_:))))
        menu.addItem(
            item("Border Selection…", #selector(EditorViewController.borderSelection(_:))))
        menu.addItem(
            item("Smooth Selection…", #selector(EditorViewController.smoothSelection(_:))))
        menu.addItem(.separator())
        // Selections ⇄ alpha channels, and the nine luminosity masks the
        // composite's luma builds.
        menu.addItem(
            item("Save Selection…", #selector(EditorViewController.saveSelectionSheet(_:))))
        menu.addItem(
            item("Load Selection…", #selector(EditorViewController.loadSelectionSheet(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item("Add Luminosity Masks", #selector(EditorViewController.addLuminosityMasks(_:))))
        menu.addItem(.separator())
        // Deliberately NO key equivalent: the bare Q toggles the mode from
        // the canvas's keyDown alongside the tool keys, so it can never
        // steal the letter from text editing (the Edit > Clear ⌫ hazard).
        menu.addItem(
            item("Quick Mask Mode", #selector(EditorViewController.toggleQuickMask(_:))))
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
        menu.addItem(item("Crop", #selector(EditorViewController.cropToSelection(_:)), "k"))
        menu.addItem(
            item("Image Size…", #selector(EditorViewController.resizeImage(_:)), "i", [.command, .option]))
        menu.addItem(
            item("Canvas Size…", #selector(EditorViewController.showCanvasSize(_:)), "c", [.command, .option]))
        menu.addItem(.separator())
        // Colour is document state too, so Mode sits with Image Size and
        // Canvas Size rather than under a preferences window.
        menu.addItem(submenuItem(modeMenu()))
        menu.addItem(.separator())
        // The destructive adjustments live here, next to Mode and Image
        // Size, rather than under Filters: they change the picture's tone
        // and colour, while Filters holds the true pixel filters (blur,
        // sharpen, pixelate, noise, edge detect, emboss). Every item is the
        // twin of an adjustment layer of the same name and runs the
        // identical core op.
        menu.addItem(submenuItem(adjustmentsMenu()))
        menu.addItem(.separator())
        menu.addItem(
            item("Auto Tone", #selector(EditorViewController.autoTone(_:)), "l",
                 [.command, .shift]))
        menu.addItem(
            item("Auto Contrast", #selector(EditorViewController.autoContrast(_:)), "l",
                 [.command, .shift, .option]))
        menu.addItem(
            item("Auto Color", #selector(EditorViewController.autoColor(_:)), "b",
                 [.command, .shift]))
        menu.addItem(.separator())
        // Channel arithmetic and the channel list itself live under Image,
        // not Layer: channels are DOCUMENT state, next to Image Size and
        // Canvas Size.
        menu.addItem(item("Apply Image…", #selector(EditorViewController.applyImageSheet(_:))))
        menu.addItem(
            item("Calculations…", #selector(EditorViewController.calculationsSheet(_:))))
        menu.addItem(submenuItem(channelsMenu()))
        return menu
    }

    /// Image > Adjustments: every tone and colour adjustment that rewrites
    /// the active layer's pixels, in Photoshop's grouping with ours folded
    /// in — tonal, then colour, then mapping, then the odds and ends. The
    /// twelve phase-5 ops share one selector, each item's tag indexing
    /// `AdjustmentMenuOrder.newOps` (layerStyleMenu's idiom); the older
    /// items keep the selectors and shortcuts they already had.
    private func adjustmentsMenu() -> NSMenu {
        let menu = NSMenu(title: "Adjustments")
        func destructive(_ op: AdjustmentLayerOp) -> NSMenuItem {
            let entry = item(
                op.displayName + "…", #selector(EditorViewController.showAdjustmentSheet(_:)))
            // Every op passed here is in the list, so the fallback is
            // unreachable; it exists so a mis-edit beeps rather than
            // opening the wrong op's dialog.
            entry.tag = AdjustmentMenuOrder.newOps.firstIndex(of: op) ?? -1
            return entry
        }
        menu.addItem(
            item(
                "Brightness/Contrast/Saturation…",
                #selector(EditorViewController.showAdjustments(_:)), "a",
                [.command, .option]))
        menu.addItem(item("Levels…", #selector(EditorViewController.showLevels(_:))))
        menu.addItem(destructive(.exposure))
        menu.addItem(.separator())
        menu.addItem(destructive(.vibrance))
        menu.addItem(destructive(.hueSaturation))
        menu.addItem(destructive(.colorBalance))
        menu.addItem(destructive(.blackAndWhite))
        menu.addItem(destructive(.photoFilter))
        menu.addItem(destructive(.channelMixer))
        menu.addItem(destructive(.colorLookup))
        menu.addItem(.separator())
        menu.addItem(item("Invert", #selector(EditorViewController.applyInvert(_:)), "i"))
        menu.addItem(item("Posterize…", #selector(EditorViewController.showPosterize(_:))))
        menu.addItem(item("Threshold…", #selector(EditorViewController.showThreshold(_:))))
        menu.addItem(destructive(.gradientMap))
        menu.addItem(destructive(.selectiveColor))
        menu.addItem(.separator())
        menu.addItem(destructive(.shadowsHighlights))
        menu.addItem(destructive(.whiteBalance))
        menu.addItem(item("Hue Rotate…", #selector(EditorViewController.showHueRotate(_:))))
        menu.addItem(item("Grayscale", #selector(EditorViewController.applyGrayscale(_:))))
        menu.addItem(item("Sepia", #selector(EditorViewController.applySepia(_:))))
        return menu
    }

    /// Image > Mode: the document's colour profile (relabel vs. convert)
    /// and, one level down, the app-wide working space new opens are
    /// converted into. Neither profile command earns a key equivalent —
    /// they are deliberate, occasional acts. Enablement and the working
    /// space's check marks come from
    /// EditorViewController.validateUserInterfaceItem.
    private func modeMenu() -> NSMenu {
        let menu = NSMenu(title: "Mode")
        menu.addItem(
            item("Assign Profile…", #selector(EditorViewController.assignProfile(_:))))
        menu.addItem(
            item("Convert to Profile…", #selector(EditorViewController.convertToProfile(_:))))
        menu.addItem(.separator())
        menu.addItem(submenuItem(workingSpaceMenu()))
        return menu
    }

    /// Image > Mode > Working Space: one check-marked radio item per
    /// WorkingSpace, its tag indexing `WorkingSpace.allCases` (the
    /// layerStyleMenu tag idiom). It affects FUTURE opens only.
    private func workingSpaceMenu() -> NSMenu {
        let menu = NSMenu(title: "Working Space")
        for (tag, space) in WorkingSpace.allCases.enumerated() {
            let entry = item(space.displayName, #selector(setWorkingSpace(_:)))
            entry.tag = tag
            menu.addItem(entry)
        }
        return menu
    }

    private func channelsMenu() -> NSMenu {
        let menu = NSMenu(title: "Channels")
        menu.addItem(item("New Channel", #selector(EditorViewController.newChannel(_:))))
        menu.addItem(
            item("Duplicate Channel", #selector(EditorViewController.duplicateChannel(_:))))
        menu.addItem(item("Delete Channel", #selector(EditorViewController.deleteChannel(_:))))
        menu.addItem(
            item("Channel Options…", #selector(EditorViewController.channelOptions(_:))))
        menu.addItem(item("Invert Channel", #selector(EditorViewController.invertChannel(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item(
                "Load Channel as Selection",
                #selector(EditorViewController.loadChannelAsSelection(_:))))
        return menu
    }

    private func layerMenu() -> NSMenu {
        let menu = NSMenu(title: "Layer")
        menu.addItem(
            item("New Layer", #selector(EditorViewController.newLayer(_:)), "n", [.command, .shift]))
        menu.addItem(submenuItem(newAdjustmentLayerMenu()))
        // Imports a Live Photo as a layer showing its key frame; Select Live
        // Photo Frame… below then scrubs that layer's timeline.
        menu.addItem(
            item("Place Live Photo…", #selector(EditorViewController.placeLivePhoto(_:))))
        // ⌘J moves to Layer Via Copy below, which is where Photoshop has
        // it; Duplicate Layer keeps its item and the panel's button. The
        // ACTION behind ⌘J routes back here for a group, an adjustment
        // layer, a described layer, several layers selected, or no selection
        // (EditorViewController+MergeStamp.swift) — layer_via is a
        // single-entry op, so acting on the primary alone would silently
        // drop the rest of a multi-selection.
        menu.addItem(item("Duplicate Layer", #selector(EditorViewController.duplicateLayer(_:))))
        menu.addItem(item("Delete Layer", #selector(EditorViewController.deleteLayer(_:))))
        menu.addItem(.separator())
        // Layer groups. ⌘G / ⇧⌘G are Photoshop's; ⌥⌘G (Create Clipping
        // Mask, below) is untouched.
        menu.addItem(item("New Group", #selector(EditorViewController.groupLayers(_:)), "g"))
        menu.addItem(
            item(
                "Ungroup Layers", #selector(EditorViewController.ungroupLayers(_:)), "g",
                [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Layer Via Copy", #selector(EditorViewController.layerViaCopy(_:)), "j"))
        menu.addItem(
            item(
                "Layer Via Cut", #selector(EditorViewController.layerViaCut(_:)), "j",
                [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(submenuItem(arrangeMenu()))
        menu.addItem(submenuItem(alignMenu()))
        menu.addItem(submenuItem(distributeMenu()))
        menu.addItem(submenuItem(lockMenu()))
        menu.addItem(.separator())
        menu.addItem(item("Link Layers", #selector(EditorViewController.linkLayers(_:))))
        menu.addItem(item("Unlink Layers", #selector(EditorViewController.unlinkLayers(_:))))
        menu.addItem(.separator())
        // Modal on-canvas session, not a tool: Return commits, Escape cancels.
        menu.addItem(item("Free Transform", #selector(EditorViewController.freeTransform(_:)), "t"))
        menu.addItem(.separator())
        menu.addItem(submenuItem(layerMaskMenu()))
        // One toggling item, retitled "Release Clipping Mask" in
        // EditorViewController.validateUserInterfaceItem when the active
        // layer is already clipped (Photoshop convention).
        menu.addItem(
            item(
                "Create Clipping Mask",
                #selector(EditorViewController.toggleClippingMask(_:)), "g",
                [.command, .option]))
        // Re-opens the active adjustment layer's dialog; enabled only for an
        // adjustment layer whose op has one (validation in the editor).
        menu.addItem(
            item("Adjustment Options…", #selector(EditorViewController.adjustmentOptions(_:))))
        menu.addItem(submenuItem(layerStyleMenu()))
        // Enabled only on a layer that still carries its Live Photo
        // description (validation in the editor).
        menu.addItem(
            item(
                "Select Live Photo Frame…",
                #selector(EditorViewController.selectLivePhotoFrame(_:))))
        menu.addItem(.separator())
        // Retitled "Merge Layers" by the editor's validation when several
        // entries are selected (Photoshop's own retitle).
        menu.addItem(
            item("Merge Down", #selector(EditorViewController.mergeDown(_:)), "e", [.command, .shift]))
        // Deliberately no key equivalent: Photoshop's ⇧⌘E is this build's
        // Merge Down and its ⌘E is File ▸ Export, and renegotiating either
        // silently would break a habit that already exists here.
        menu.addItem(item("Merge Visible", #selector(EditorViewController.mergeVisible(_:))))
        menu.addItem(
            item(
                "Stamp Visible", #selector(EditorViewController.stampVisible(_:)), "e",
                [.command, .shift, .option]))
        menu.addItem(item("Flatten Image", #selector(EditorViewController.flattenImage(_:))))
        return menu
    }

    /// Layer ▸ Arrange. Each item moves the entry among its SIBLINGS only —
    /// never into or out of a group; a drag in the panel, or reorder_layer
    /// with a depth, is how an entry changes level.
    private func arrangeMenu() -> NSMenu {
        let menu = NSMenu(title: "Arrange")
        menu.addItem(
            item(
                "Bring to Front", #selector(EditorViewController.bringToFront(_:)), "]",
                [.command, .shift]))
        menu.addItem(
            item("Bring Forward", #selector(EditorViewController.bringForward(_:)), "]"))
        menu.addItem(
            item("Send Backward", #selector(EditorViewController.sendBackward(_:)), "["))
        menu.addItem(
            item(
                "Send to Back", #selector(EditorViewController.sendToBack(_:)), "[",
                [.command, .shift]))
        return menu
    }

    /// Layer ▸ Align. Aligns the selection's CONTENT bounds — the box of
    /// actually opaque pixels, which for a canvas-sized layer is nothing
    /// like its pixel rect.
    private func alignMenu() -> NSMenu {
        let menu = NSMenu(title: "Align")
        menu.addItem(item("Left Edges", #selector(EditorViewController.alignLeft(_:))))
        menu.addItem(
            item("Horizontal Centers", #selector(EditorViewController.alignCenterX(_:))))
        menu.addItem(item("Right Edges", #selector(EditorViewController.alignRight(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Top Edges", #selector(EditorViewController.alignTop(_:))))
        menu.addItem(item("Vertical Centers", #selector(EditorViewController.alignCenterY(_:))))
        menu.addItem(item("Bottom Edges", #selector(EditorViewController.alignBottom(_:))))
        return menu
    }

    /// Layer ▸ Distribute. Equalizes the GAPS between adjacent entries, so
    /// it needs three of them (validation in the editor).
    private func distributeMenu() -> NSMenu {
        let menu = NSMenu(title: "Distribute")
        menu.addItem(
            item(
                "Horizontal Spacing",
                #selector(EditorViewController.distributeHorizontally(_:))))
        menu.addItem(
            item("Vertical Spacing", #selector(EditorViewController.distributeVertically(_:))))
        return menu
    }

    /// Layer ▸ Lock. Each item toggles its own bit over the selection, with
    /// the checkmark showing the active layer's state; Lock All is the three
    /// bits together (PSD's own spelling), on ⌘/.
    private func lockMenu() -> NSMenu {
        let menu = NSMenu(title: "Lock")
        menu.addItem(
            item("Transparency", #selector(EditorViewController.lockTransparency(_:))))
        menu.addItem(item("Pixels", #selector(EditorViewController.lockPixels(_:))))
        menu.addItem(item("Position", #selector(EditorViewController.lockPosition(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Lock All", #selector(EditorViewController.lockAll(_:)), "/"))
        return menu
    }

    /// Layer > New Adjustment Layer: one item per adjustment op, named like
    /// the destructive Filters items where they overlap, grouped
    /// parameterized (dialog) before parameterless (immediate) the way the
    /// Filters menu groups its own.
    private func newAdjustmentLayerMenu() -> NSMenu {
        let menu = NSMenu(title: "New Adjustment Layer")
        menu.addItem(
            item(
                "Brightness/Contrast/Saturation…",
                #selector(EditorViewController.newAdjustmentLayerBCS(_:))))
        menu.addItem(
            item("Curves…", #selector(EditorViewController.newAdjustmentLayerCurves(_:))))
        menu.addItem(
            item("Levels…", #selector(EditorViewController.newAdjustmentLayerLevels(_:))))
        menu.addItem(
            item("Hue Rotate…", #selector(EditorViewController.newAdjustmentLayerHueRotate(_:))))
        menu.addItem(
            item("Posterize…", #selector(EditorViewController.newAdjustmentLayerPosterize(_:))))
        menu.addItem(
            item("Threshold…", #selector(EditorViewController.newAdjustmentLayerThreshold(_:))))
        // The phase-5 ops, in AdjustmentMenuOrder's one order (shared with
        // Image > Adjustments and the panel footer), tag-indexed into it.
        for (tag, op) in AdjustmentMenuOrder.newOps.enumerated() {
            let entry = item(
                op.displayName + "…",
                #selector(EditorViewController.newAdjustmentLayerOp(_:)))
            entry.tag = tag
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(
            item("Invert", #selector(EditorViewController.newAdjustmentLayerInvert(_:))))
        menu.addItem(
            item("Grayscale", #selector(EditorViewController.newAdjustmentLayerGrayscale(_:))))
        menu.addItem(
            item("Sepia", #selector(EditorViewController.newAdjustmentLayerSepia(_:))))
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

    /// Layer > Layer Style: Blending Options…, one item per effect (each
    /// opens the sheet on that effect, turned on — the item's tag indexes
    /// LayerStyleEffectKind.allCases, Photoshop's dialog order), then
    /// Copy / Paste / Clear. Enablement comes from
    /// EditorViewController.validateUserInterfaceItem.
    private func layerStyleMenu() -> NSMenu {
        let menu = NSMenu(title: "Layer Style")
        menu.addItem(
            item("Blending Options…", #selector(EditorViewController.layerStyle(_:))))
        menu.addItem(.separator())
        for (tag, kind) in LayerStyleEffectKind.allCases.enumerated() {
            let entry = item(
                kind.title + "…", #selector(EditorViewController.layerStyleEffect(_:)))
            entry.tag = tag
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(
            item("Copy Layer Style", #selector(EditorViewController.copyLayerStyle(_:))))
        menu.addItem(
            item("Paste Layer Style", #selector(EditorViewController.pasteLayerStyle(_:))))
        menu.addItem(
            item("Clear Layer Style", #selector(EditorViewController.clearLayerStyle(_:))))
        return menu
    }

    /// Filters: the true PIXEL filters. Every tone and colour adjustment
    /// moved to Image > Adjustments when the batch grew past what one flat
    /// menu can carry — same selectors, same shortcuts, same behaviour.
    private func filtersMenu() -> NSMenu {
        let menu = NSMenu(title: "Filters")
        // ⌃F, as Photoshop spells it. The title becomes Repeat "Sharpen"
        // when there is something to repeat (EditorViewController+Actions
        // .validateActionsItem), which also disables it while text is being
        // edited: NSTextView binds ⌃F to moveForward:, and a menu key
        // equivalent is resolved AHEAD of the first responder — the same trap
        // Edit ▸ Clear's bare ⌫ carries, and answered the same way.
        menu.addItem(
            item(
                "Repeat Last Filter",
                #selector(EditorViewController.repeatLastFilter(_:)), "f", [.control]))
        menu.addItem(.separator())
        menu.addItem(item("Gaussian Blur…", #selector(EditorViewController.showBlur(_:))))
        menu.addItem(item("Sharpen", #selector(EditorViewController.applySharpen(_:))))
        menu.addItem(item("Pixelate…", #selector(EditorViewController.showPixelate(_:))))
        menu.addItem(item("Add Noise…", #selector(EditorViewController.showAddNoise(_:))))
        menu.addItem(item("Edge Detect", #selector(EditorViewController.applyEdgeDetect(_:))))
        menu.addItem(item("Emboss", #selector(EditorViewController.applyEmboss(_:))))
        menu.addItem(.separator())
        // The AUTOMATIC red-eye pass: Vision's face landmarks find the eyes
        // and the same core op runs on each. The Red Eye tool's drag
        // rectangle is the manual route.
        menu.addItem(
            item("Remove Red Eye", #selector(EditorViewController.removeRedEye(_:))))
        return menu
    }

    private func toolsMenu() -> NSMenu {
        // Deliberately no key equivalents: the bare tool keys (v/b/e/t) are
        // handled in ImageCanvasView.keyDown so they never steal keystrokes
        // from text editing. Built from the rail's own groups, in rail
        // order, so this menu and the rail can never disagree about the
        // tool set; a planned tool's item is validation-disabled.
        let menu = NSMenu(title: "Tools")
        for group in EditorTool.railGroups {
            for tool in group {
                menu.addItem(item("\(tool.displayName) Tool", tool.action))
            }
        }
        menu.addItem(.separator())
        // ⇧⌘K, not the ⌘K the brief asks for: ⌘K is Crop, and a shortcut
        // already in the user's fingers is never silently renegotiated.
        // The Tools menu is the right home — it already carries the one
        // app-utility item that is not a tool.
        menu.addItem(
            item(
                "Command Palette…", #selector(showCommandPalette(_:)), "k",
                [.command, .shift]))
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
                "Channels", #selector(EditorViewController.showChannels(_:)), "c",
                [.command, .control]))
        menu.addItem(
            item(
                "Assistant", #selector(EditorViewController.showAssistant(_:)), "a",
                [.command, .control]))
        menu.addItem(
            item(
                "Info", #selector(EditorViewController.showInfo(_:)), "i",
                [.command, .control]))
        menu.addItem(.separator())
        // Photoshop puts Rulers on ⌘R, which is TAKEN here by Image > Rotate
        // 90° Clockwise — and renegotiating a shortcut silently is exactly
        // what the Merge Visible comment below forbids. ⌃⌘R is free and is
        // the View menu's own convention (Channels ⌃⌘C, Assistant ⌃⌘A,
        // Info ⌃⌘I). Every other shortcut in this block is Photoshop's own.
        menu.addItem(
            item(
                "Rulers", #selector(EditorViewController.toggleRulers(_:)), "r",
                [.command, .control]))
        menu.addItem(submenuItem(rulerUnitsMenu()))
        menu.addItem(.separator())
        menu.addItem(
            item("Show Guides", #selector(EditorViewController.toggleGuides(_:)), ";"))
        menu.addItem(
            item(
                "Lock Guides", #selector(EditorViewController.toggleLockGuides(_:)), ";",
                [.command, .option]))
        menu.addItem(item("Clear Guides", #selector(EditorViewController.clearGuides(_:))))
        menu.addItem(item("New Guide…", #selector(EditorViewController.newGuide(_:))))
        menu.addItem(submenuItem(guideColorMenu()))
        menu.addItem(.separator())
        menu.addItem(item("Show Grid", #selector(EditorViewController.toggleGrid(_:)), "'"))
        menu.addItem(submenuItem(gridSpacingMenu()))
        menu.addItem(submenuItem(gridSubdivisionsMenu()))
        menu.addItem(.separator())
        menu.addItem(
            item(
                "Snap", #selector(EditorViewController.toggleSnap(_:)), ";",
                [.command, .shift]))
        menu.addItem(submenuItem(snapToMenu()))
        return menu
    }

    /// View ▸ Ruler Units: one radio item per CanvasUnit, its tag indexing
    /// `CanvasUnit.allCases` (the workingSpaceMenu idiom).
    private func rulerUnitsMenu() -> NSMenu {
        let menu = NSMenu(title: "Ruler Units")
        for (tag, unit) in CanvasUnit.allCases.enumerated() {
            let entry = item(unit.displayName, #selector(EditorViewController.setRulerUnit(_:)))
            entry.tag = tag
            menu.addItem(entry)
        }
        return menu
    }

    /// View ▸ Guide Color, tag-indexing `GuideColor.allCases`.
    private func guideColorMenu() -> NSMenu {
        let menu = NSMenu(title: "Guide Color")
        for (tag, color) in GuideColor.allCases.enumerated() {
            let entry = item(
                color.displayName, #selector(EditorViewController.setGuideColor(_:)))
            entry.tag = tag
            menu.addItem(entry)
        }
        return menu
    }

    /// View ▸ Grid Spacing — presets in the CURRENT ruler unit, so the same
    /// 100 is 100 px, 100 in or 100 % depending on View ▸ Ruler Units.
    private func gridSpacingMenu() -> NSMenu {
        let menu = NSMenu(title: "Grid Spacing")
        for (tag, spacing) in CanvasGrid.spacingPresets.enumerated() {
            let entry = item(
                "\(Int(spacing))", #selector(EditorViewController.setGridSpacing(_:)))
            entry.tag = tag
            menu.addItem(entry)
        }
        return menu
    }

    private func gridSubdivisionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Grid Subdivisions")
        for (tag, count) in CanvasGrid.subdivisionPresets.enumerated() {
            let entry = item(
                "\(count)", #selector(EditorViewController.setGridSubdivisions(_:)))
            entry.tag = tag
            menu.addItem(entry)
        }
        return menu
    }

    /// View ▸ Snap To: five independent bits plus All / None — the Layer ▸
    /// Lock template with a different set, so five toggles cost ONE selector
    /// (the tag indexes `SnapTarget.named`).
    private func snapToMenu() -> NSMenu {
        let menu = NSMenu(title: "Snap To")
        for (tag, target) in SnapTarget.named.enumerated() {
            let entry = item(
                target.name, #selector(EditorViewController.toggleSnapTarget(_:)))
            entry.tag = tag
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("All", #selector(EditorViewController.snapToAll(_:))))
        menu.addItem(item("None", #selector(EditorViewController.snapToNone(_:))))
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
