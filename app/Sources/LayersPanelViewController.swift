import AppKit

/// Right-hand layers panel: blend mode + opacity for the selection on top,
/// the layer stack (row 0 = TOPMOST entry) in the middle, and the
/// add/group/adjustment/duplicate/delete buttons below. All edits route
/// through ImageDocument.applyEdit (or the live-edit API for opacity
/// scrubs); the footer buttons send the same nil-target actions the Layer
/// menu uses, so EditorViewController handles both.
///
/// The stack is a TREE: a group's children are rows under it, and a closed
/// group hides them. Rows are therefore no longer `layerCount - 1 - row` —
/// `rows` is the explicit mapping, rebuilt on every reload from `LayerTree`,
/// the idiom the Channels panel already uses.
///
/// **The seam `LayersPanelViewController+Rows.swift` builds on** — `rows`,
/// `tree`, `row(forLayerIndex:)`, `layerIndex(forRow:)` and `isReloading` —
/// is deliberately `internal`, not `private`: Swift's `private` is
/// file-scoped, and the selection, drag and row-menu delegate methods live
/// in that file (`app/CLAUDE.md`: the pieces an extension file builds on are
/// internal).
final class LayersPanelViewController: NSViewController {
    weak var document: ImageDocument?

    /// Called when the user changes the active layer via the table selection
    /// (the editor updates its status bar).
    var onActiveLayerChange: (() -> Void)?

    /// Called when the user clicks the Channels tab.
    var onShowChannels: (() -> Void)?

    /// Called when the user clicks the Assistant tab.
    var onShowAssistant: (() -> Void)?

    /// Called when the user clicks the Info tab.
    var onShowInfo: (() -> Void)?

    /// Called on a ⌘-click on a layer's own thumbnail (`.layer` — load its
    /// transparency) or its mask thumbnail (`.mask` — load the mask), with
    /// the selection tools' modifier convention for the combine mode.
    /// Loading a selection is never an edit.
    var onLoadLayerSelection: ((Int, PaintTarget, SelectionCombineMode) -> Void)?

    /// Called when the user clicks a layer's own thumbnail or its mask
    /// thumbnail: the editor points brush/eraser at that target.
    var onPaintTargetChange: ((PaintTarget) -> Void)?

    /// Called when the user double-clicks an adjustment layer (layer index
    /// attached): the editor reopens its options dialog.
    var onAdjustmentEdit: ((Int) -> Void)?

    /// Called when the user double-clicks a text layer (layer index
    /// attached): the editor switches to the text tool and reopens the
    /// layer's description on the canvas.
    var onTextEdit: ((Int) -> Void)?

    /// Called when the user double-clicks a live photo layer, or picks
    /// Select Frame… from its row menu (layer index attached): the editor
    /// opens that layer's frame picker.
    var onLivePhotoEdit: ((Int) -> Void)?

    /// Called when the user double-clicks a shape layer (layer index
    /// attached): the editor switches to the matching shape tool and
    /// reopens the layer's box on the canvas.
    var onShapeEdit: ((Int) -> Void)?

    /// Called when the user picks Layer Style… from a row's menu, or
    /// double-clicks a layer that has no source to reopen (Photoshop's row
    /// double-click): the editor opens that layer's style sheet.
    var onLayerStyleEdit: ((Int) -> Void)?

    /// What brush/eraser currently edit on the active layer, pushed in by the
    /// editor and drawn as a focus ring around the matching thumbnail.
    private(set) var paintTarget: PaintTarget = .layer

    private let blendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let blendContainer = NSView()
    private let opacitySlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    private let layerCountLabel = NSTextField(labelWithString: "")
    /// Internal, not private: the selection, drag and row-menu delegate
    /// methods live in `+Rows.swift`, which has to read the clicked and
    /// selected rows.
    let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private var addButton: NSButton!
    private var groupButton: NSButton!
    private var adjustmentButton: NSButton!
    private var duplicateButton: NSButton!
    private var deleteButton: NSButton!

    private let rowMenu = NSMenu()

    /// The table's rows, TOP-FIRST, rebuilt by `reload()`. The single
    /// mapping between a row and an entry index: a closed group's children
    /// have no row at all, so the old `layerCount - 1 - row` arithmetic
    /// cannot express this and is gone.
    private(set) var rows: [LayerRowModel] = []

    /// The structure the rows were built from, kept for the drag code (a
    /// drop onto a group row needs its depth) and the row menu.
    private(set) var tree = LayerTree([])

    /// Whether the blend popup currently offers Pass Through, so the menu is
    /// rebuilt only when the primary entry's KIND changes rather than on
    /// every header refresh.
    private var blendMenuHasPassThrough = false

    var isReloading = false
    private var opacityDragActive = false

    static let layerRowType = NSPasteboard.PasteboardType("com.kgalligan.rasterize.layerrow")

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LayersPanelViewController does not support NSCoder")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: DS.panelWidth, height: 400))
        root.wantsLayer = true

        // Panel tab row: Layers active here, Channels and Assistant switch
        // over.
        let tab = PanelTabsView(
            titles: ["Layers", "Channels", "Assistant", "Info"], activeIndex: 0
        ) { [weak self] index in
            if index == 1 { self?.onShowChannels?() }
            if index == 2 { self?.onShowAssistant?() }
            if index == 3 { self?.onShowInfo?() }
        }
        tab.translatesAutoresizingMaskIntoConstraints = false

        blendContainer.translatesAutoresizingMaskIntoConstraints = false
        blendContainer.wantsLayer = true
        blendContainer.layer?.cornerRadius = 7
        blendContainer.layer?.borderWidth = 1.5

        blendPopup.translatesAutoresizingMaskIntoConstraints = false
        blendPopup.isBordered = false
        blendPopup.font = DS.sans(13)
        installBlendMenu(passThrough: false)
        blendPopup.target = self
        blendPopup.action = #selector(blendChanged(_:))

        blendContainer.addSubview(blendPopup)

        let opacityTitle = NSTextField(labelWithString: "")
        opacityTitle.translatesAutoresizingMaskIntoConstraints = false
        opacityTitle.attributedStringValue = DS.microLabel("Opacity")

        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.isContinuous = true
        opacitySlider.controlSize = .small
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))

        opacityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        opacityValueLabel.font = DS.mono(11)
        opacityValueLabel.textColor = DS.textMuted
        opacityValueLabel.alignment = .right

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = DS.panelWidth - 20
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Keep keyboard focus on the canvas: clicks still select rows, and
        // inline rename focuses its own field editor, but arrow keys must
        // keep nudging/tool keys working instead of walking the layer list.
        tableView.refusesFirstResponder = true
        tableView.rowHeight = DS.layerRow
        // ⇧-click extends and ⌘-click toggles, so move, transform, align,
        // group and merge can act on a set. Empty stays forbidden: a
        // document always has an active layer.
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.layerRowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        // Double-click anywhere on a row reopens the layer's source, the same
        // gesture its thumbnail offers; right-click opens the row menu. Both
        // read tableView.clickedRow, so they act on the row under the cursor
        // rather than on the selection.
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        rowMenu.delegate = self
        tableView.menu = rowMenu

        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain

        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false

        // Footer: four ghost icon buttons, mono layer count right. nil
        // targets: actions resolve through the responder chain to the
        // EditorViewController, the same handlers the Layer menu items use.
        // The adjustment button is the exception — it pops the same per-op
        // menu as Layer > New Adjustment Layer, so it targets the panel.
        addButton = GhostButton(
            symbol: "plus", fallback: "+", caption: nil, tooltip: "New Layer",
            action: #selector(EditorViewController.newLayer(_:)))
        groupButton = GhostButton(
            symbol: "folder.badge.plus", fallback: "▣", caption: nil, tooltip: "New Group",
            action: #selector(EditorViewController.groupLayers(_:)))
        adjustmentButton = GhostButton(
            symbol: "circle.righthalf.filled", fallback: "◐", caption: nil,
            tooltip: "New Adjustment Layer",
            action: #selector(showNewAdjustmentMenu(_:)))
        adjustmentButton.target = self
        duplicateButton = GhostButton(
            symbol: "plus.square.on.square", fallback: "⧉", caption: nil,
            tooltip: "Duplicate Layer",
            action: #selector(EditorViewController.duplicateLayer(_:)))
        deleteButton = GhostButton(
            symbol: "trash", fallback: "✕", caption: nil, tooltip: "Delete Layer",
            action: #selector(EditorViewController.deleteLayer(_:)))

        layerCountLabel.translatesAutoresizingMaskIntoConstraints = false
        layerCountLabel.font = DS.mono(10)
        layerCountLabel.textColor = DS.textFaint
        layerCountLabel.alignment = .right

        let footerSeparator = NSView()
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.wantsLayer = true

        let footerSpacer = NSView()
        let footer = NSStackView(views: [
            addButton, groupButton, adjustmentButton, duplicateButton, deleteButton,
            footerSpacer, layerCountLabel,
        ])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.spacing = 2
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 12)

        root.addSubview(tab)
        root.addSubview(blendContainer)
        root.addSubview(opacityTitle)
        root.addSubview(opacitySlider)
        root.addSubview(opacityValueLabel)
        root.addSubview(tableScroll)
        root.addSubview(footerSeparator)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            // The tab row runs edge to edge; the content below keeps its
            // 12px insets.
            tab.topAnchor.constraint(equalTo: root.topAnchor),
            tab.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tab.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tab.heightAnchor.constraint(equalToConstant: DS.tabHeight),

            blendContainer.topAnchor.constraint(equalTo: tab.bottomAnchor, constant: 12),
            blendContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            blendContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            blendContainer.heightAnchor.constraint(equalToConstant: 30),

            blendPopup.leadingAnchor.constraint(equalTo: blendContainer.leadingAnchor, constant: 8),
            blendPopup.trailingAnchor.constraint(
                equalTo: blendContainer.trailingAnchor, constant: -6),
            blendPopup.centerYAnchor.constraint(equalTo: blendContainer.centerYAnchor),

            opacityTitle.centerYAnchor.constraint(equalTo: opacitySlider.centerYAnchor),
            opacityTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),

            opacitySlider.topAnchor.constraint(equalTo: blendContainer.bottomAnchor, constant: 10),
            opacitySlider.leadingAnchor.constraint(
                equalTo: opacityTitle.trailingAnchor, constant: 8),
            opacitySlider.trailingAnchor.constraint(
                equalTo: opacityValueLabel.leadingAnchor, constant: -6),

            opacityValueLabel.centerYAnchor.constraint(equalTo: opacitySlider.centerYAnchor),
            opacityValueLabel.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -12),
            opacityValueLabel.widthAnchor.constraint(equalToConstant: 40),

            tableScroll.topAnchor.constraint(equalTo: opacitySlider.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footerSeparator.topAnchor.constraint(equalTo: tableScroll.bottomAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),

            footer.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 36),
        ])

        view = root
        applyPanelAppearance(separator: footerSeparator)
    }

    /// Builds the blend popup's menu, with Pass Through at the top when the
    /// primary entry is a GROUP — the one place that mode means anything
    /// (the core refuses it on a raster layer), and Photoshop's default for
    /// a new group.
    ///
    /// Separators mean item position != mode index, so every item carries
    /// its RzBlendMode raw value in `tag`; selection goes through tags,
    /// never item positions.
    private func installBlendMenu(passThrough: Bool) {
        let menu = NSMenu()
        if passThrough {
            // The NAME comes from the one place that spells it
            // (RzBlendMode.displayName); only the position is decided here.
            let item = NSMenuItem(
                title: RzBlendMode.displayName(for: RZ_BLEND_PASS_THROUGH),
                action: nil, keyEquivalent: "")
            item.tag = Int(RZ_BLEND_PASS_THROUGH.rawValue)
            menu.addItem(item)
        }
        for (groupIndex, group) in RzBlendMode.blendModeGroups.enumerated() {
            if groupIndex > 0 || passThrough {
                menu.addItem(NSMenuItem.separator())
            }
            for (mode, title) in group {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = Int(mode.rawValue)
                menu.addItem(item)
            }
        }
        blendPopup.menu = menu
        blendMenuHasPassThrough = passThrough
    }

    /// Colors that need explicit refresh on appearance changes (layer-backed
    /// borders resolve cgColor once).
    private func applyPanelAppearance(separator: NSView) {
        view.layer?.backgroundColor = DS.chromeBackground.cgColor
        blendContainer.layer?.borderColor = DS.borderStrong.cgColor
        blendContainer.layer?.backgroundColor = DS.chromeBackground.cgColor
        separator.layer?.backgroundColor = DS.border.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentDidChange(_:)),
            name: .imageDocumentImageDidChange, object: document)
        reload()
    }

    @objc private func documentDidChange(_ note: Notification) {
        // Live-edit ticks (Move drags, opacity scrubs) arrive per mouse
        // event; nothing structural changes mid-gesture, so rebuilding the
        // table (and re-resampling every layer's thumbnail) each tick only
        // burns CPU. Refresh the cheap header controls and wait for the
        // gesture's final non-live post to do the one full reload. If the
        // userInfo key is absent (older sender), fall back to the document's
        // flag and, failing that, our own scrub state.
        let isLive = (note.userInfo?["isLive"] as? Bool)
            ?? document?.isLiveEditing
            ?? false
        if isLive || opacityDragActive {
            updateHeaderControls()
            return
        }
        reload()
    }

    // MARK: - Row/layer mapping (row 0 = TOPMOST entry)

    /// The entry a row names; nil for a row that no longer exists (the table
    /// asks about rows across a reload).
    func layerIndex(forRow row: Int) -> Int? {
        guard row >= 0, row < rows.count else { return nil }
        return rows[row].index
    }

    /// The row an entry is shown on; nil when it has none — a layer inside a
    /// COLLAPSED group is selected and edited normally, it simply has no row
    /// of its own.
    func row(forLayerIndex idx: Int) -> Int? {
        rows.firstIndex { $0.index == idx }
    }

    // MARK: - Reload

    /// Rebuilds `rows` from the document's structure, reloads the table,
    /// restores the WHOLE selection, and refreshes header + buttons.
    ///
    /// The row models carry no thumbnails: those are resampled by the cells
    /// AppKit actually asks for, so a hundred-layer document does not
    /// regenerate a hundred images on every reload.
    func reload() {
        guard isViewLoaded else { return }
        rebuildRows()
        isReloading = true
        tableView.reloadData()
        // The whole set, in one call: restoring row by row would make AppKit
        // post a selection change per row and read the round trip back as a
        // user edit.
        let selected = IndexSet(rows.indices.filter { rows[$0].isSelected })
        if !selected.isEmpty {
            tableView.selectRowIndexes(selected, byExtendingSelection: false)
        }
        isReloading = false
        updateHeaderControls()
        updateButtonStates()
    }

    /// The one place a row exists: the tree's visible rows, top-first, with
    /// everything a cell needs read once per entry.
    ///
    /// A selected entry inside a COLLAPSED group has no row of its own: the
    /// group's row stands for it, and the SELECTION is re-pointed at that row
    /// rather than only drawn there.
    private func rebuildRows() {
        guard let document = document, let doc = document.doc else {
            rows = []
            tree = LayerTree([])
            return
        }
        tree = doc.layerTree
        // Written BACK, not merely drawn. Every command reads
        // `document.activeLayerIndex` / `selectedLayerIndices`, so leaving the
        // selection on an entry with no row meant Delete Layer, Merge Down,
        // Align and the footer buttons acted on something the panel had
        // never shown as selected — the highlighted group survived while a
        // layer inside it was deleted. This is exactly the remap
        // `ImageDocument.setGroupExpanded` makes on the disclosure-click
        // path; the paths that do not go through it land here: a document
        // loaded with a closed group around its active layer, and an agent's
        // set_active_layer aimed inside one. (An agent naming a hidden entry
        // therefore ends up with its GROUP active, and a pixel tool then
        // refuses by name — which is why every agent tool takes an explicit
        // `layer`, and why none of them relies on the panel's selection.)
        document.setLayerSelection(document.layerSelection.mappedToVisibleRows(in: doc))
        let selection = document.layerSelection
        let selectedRows = selection.indices
        // The PRIMARY's row, for the same reason: a primary with no row of
        // its own would leave a single selection drawn in the weak "not the
        // primary" treatment, reading as one member of a multi-selection with
        // no active layer anywhere.
        let primaryRow = selection.primary
        rows = tree.visibleRows().compactMap { idx -> LayerRowModel? in
            guard let info = doc.layerInfo(idx) else { return nil }
            return LayerRowModel(
                index: idx,
                info: info,
                depth: info.depth,
                isGroup: info.isGroup,
                childCount: tree.children(of: idx).count,
                expanded: info.open,
                hasMask: doc.layerHasMask(idx),
                maskEnabled: doc.layerMaskEnabled(idx),
                isText: doc.textPayload(idx) != nil,
                isAdjustment: doc.layerIsAdjustment(idx),
                isLivePhoto: doc.livePhotoPayload(idx) != nil,
                isShape: doc.shapePayload(idx) != nil,
                clipped: doc.layerClipped(idx),
                // One bool FFI call per row — no style JSON copy or decode
                // on the reload path.
                hasStyle: doc.layerHasStyle(idx),
                locks: doc.lockFlags(idx),
                link: info.link,
                isSelected: selectedRows.contains(idx),
                isPrimary: idx == primaryRow,
                thumbnail: nil,
                maskThumbnail: nil,
                paintTarget: paintTarget)
        }
    }

    // MARK: - Paint target

    /// Mirrors the editor's paint target into the rows' focus rings.
    func setPaintTarget(_ target: PaintTarget) {
        paintTarget = target
        refreshTargetRings()
    }

    /// Re-rings the visible rows in place — cheaper than a reload, which
    /// would re-resample every thumbnail.
    /// Internal, not private: the selection and thumbnail-click paths in
    /// `+Rows.swift` re-ring the rows after they move the selection.
    func refreshTargetRings() {
        guard isViewLoaded, let document = document else { return }
        let active = document.activeLayerIndex
        for row in 0..<min(tableView.numberOfRows, rows.count) {
            guard
                let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? LayerCellView
            else { continue }
            cell.setTargetHighlight(
                layerActive: rows[row].index == active, target: paintTarget)
        }
    }

    /// The mask's grayscale image scaled down for its thumbnail well. Masks
    /// come back at the LAYER's full size, so the scaling happens in the core
    /// rather than at draw time.
    ///
    /// Stays `ColorProfile.sRGB` while the layer thumbnail beside it takes the
    /// document's space: a mask byte is coverage shown as grey, not a colour,
    /// so there is nothing here for a profile to describe.
    private func maskThumbnail(_ doc: RasterDocument, _ idx: Int, maxSide: Int) -> NSImage? {
        guard let mask = doc.layerMaskImage(idx), mask.width > 0, mask.height > 0 else {
            return nil
        }
        let longest = max(mask.width, mask.height)
        let scale = min(CGFloat(maxSide) / CGFloat(longest), 1)
        let w = max(Int((CGFloat(mask.width) * scale).rounded()), 1)
        let h = max(Int((CGFloat(mask.height) * scale).rounded()), 1)
        let scaled =
            (w == mask.width && h == mask.height)
            ? mask : (mask.resized(w: w, h: h, filter: RZ_FILTER_BILINEAR) ?? mask)
        guard let cgImage = scaled.makeCGImage(in: ColorProfile.sRGB) else { return nil }
        return NSImage(
            cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Internal, not private: the selection and drag delegate methods in
    /// `+Rows.swift` refresh the header after they move the selection.
    func updateHeaderControls() {
        guard let document = document, let doc = document.doc,
              let info = doc.layerInfo(document.activeLayerIndex)
        else {
            blendPopup.isEnabled = false
            opacitySlider.isEnabled = false
            opacityValueLabel.stringValue = "—"
            return
        }
        // Pass Through is offered only while the primary entry is a group —
        // the mode has no meaning anywhere else and the core refuses it.
        if info.isGroup != blendMenuHasPassThrough {
            installBlendMenu(passThrough: info.isGroup)
        }
        blendPopup.isEnabled = true
        opacitySlider.isEnabled = true
        blendPopup.selectItem(withTag: Int(info.blendMode.rawValue))
        // While the user is scrubbing, the slider and label already show the
        // in-flight value (opacityChanged set them); don't write the value
        // back into the slider mid-track.
        if !opacityDragActive {
            opacitySlider.doubleValue = info.opacity
            opacityValueLabel.stringValue = "\(Int((info.opacity * 100).rounded()))%"
        }
    }

    /// Counts LEAF layers, not entries: a group is a container, and telling
    /// the user a two-layer document has three "layers" because one of them
    /// is a folder would be wrong.
    private func updateLayerCount() {
        let count = tree.pixelLayerCount
        layerCountLabel.stringValue = count == 1 ? "1 layer" : "\(count) layers"
    }

    /// Internal for the same reason as `updateHeaderControls`.
    func updateButtonStates() {
        updateLayerCount()
        let count = document?.doc?.layerCount ?? 0
        let hasDoc = count > 0
        addButton.isEnabled = hasDoc
        groupButton.isEnabled = hasDoc
        adjustmentButton.isEnabled = hasDoc
        duplicateButton.isEnabled = hasDoc
        // Not `count > 1`: what a removal TAKES is the selection's
        // independent roots' subtrees, so deleting the one group that holds
        // the whole document is refused. Same call as the menu item's
        // validation, so the button and the item cannot disagree.
        deleteButton.isEnabled = document.map {
            $0.doc?.removalLeavesLayers($0.selectedLayerIndices) ?? false
        } ?? false
    }

    /// The footer's adjustment button: pops the same per-op menu as
    /// Layer > New Adjustment Layer (same titles, same nil-target selectors,
    /// so the editor's validation covers both).
    @objc private func showNewAdjustmentMenu(_ sender: Any?) {
        let menu = NSMenu(title: "New Adjustment Layer")
        func add(_ title: String, _ action: Selector) {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        add(
            "Brightness/Contrast/Saturation…",
            #selector(EditorViewController.newAdjustmentLayerBCS(_:)))
        add("Curves…", #selector(EditorViewController.newAdjustmentLayerCurves(_:)))
        add("Levels…", #selector(EditorViewController.newAdjustmentLayerLevels(_:)))
        add("Hue Rotate…", #selector(EditorViewController.newAdjustmentLayerHueRotate(_:)))
        add("Posterize…", #selector(EditorViewController.newAdjustmentLayerPosterize(_:)))
        add("Threshold…", #selector(EditorViewController.newAdjustmentLayerThreshold(_:)))
        menu.addItem(.separator())
        // The phase-5 ops, in AdjustmentMenuOrder's one order (the same
        // list Image ▸ Adjustments and Layer ▸ New Adjustment Layer build
        // from), each tagged with its index into it.
        for (tag, op) in AdjustmentMenuOrder.newOps.enumerated() {
            let entry = NSMenuItem(
                title: op.displayName + "…",
                action: #selector(EditorViewController.newAdjustmentLayerOp(_:)),
                keyEquivalent: "")
            entry.tag = tag
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        add("Invert", #selector(EditorViewController.newAdjustmentLayerInvert(_:)))
        add("Grayscale", #selector(EditorViewController.newAdjustmentLayerGrayscale(_:)))
        add("Sepia", #selector(EditorViewController.newAdjustmentLayerSepia(_:)))
        guard let button = adjustmentButton else { return }
        menu.popUp(
            positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    // MARK: - Header actions

    /// The header applies to the WHOLE selection — Photoshop's behaviour,
    /// and the reason `applyToSelectedLayers` tolerates a per-entry no-op:
    /// setting three layers to Multiply when one of them already is must
    /// still change the other two.
    ///
    /// Pass Through reaches only a group (the core refuses it on a raster
    /// entry), so a mixed selection quietly leaves the raster entries alone
    /// rather than failing the whole edit.
    @objc private func blendChanged(_ sender: Any?) {
        guard let document = document else { return }
        guard let tag = blendPopup.selectedItem?.tag, tag >= 0 else { return }
        let mode = RzBlendMode(rawValue: UInt32(tag))
        document.applyToSelectedLayers(
            "Layer Blend Mode",
            record: .selectionProperty(
                "blend_mode", RzBlendMode.displayName(for: mode),
                selectionCount: document.selectedLayerIndices.count,
                note: "Layer Blend Mode")
        ) { $0.withLayerBlendMode($1, mode) }
    }

    @objc private func opacityChanged(_ sender: Any?) {
        guard let document = document, document.doc != nil else { return }
        let idx = document.activeLayerIndex
        let indices = document.selectedLayerIndices
        let value = opacitySlider.doubleValue
        opacityValueLabel.stringValue = "\(Int((value * 100).rounded()))%"
        // Continuous slider ticks swap the doc live (no undo); the tick
        // delivered with the mouse-up event commits the whole scrub as ONE
        // undo step. Non-drag changes (keyboard) commit immediately.
        let eventType = NSApp.currentEvent?.type
        let stillDragging = eventType == .leftMouseDragged || eventType == .leftMouseDown
        // A no-move click reproduces the slider's assigned value exactly;
        // don't register a phantom undo step for it.
        if !opacityDragActive, !stillDragging,
           let current = document.doc.layerInfo(idx)?.opacity,
           Double(current) == value {
            return
        }
        if !opacityDragActive {
            document.beginLiveEdit()
            opacityDragActive = true
        }
        // Every selected entry follows the slider, chained onto one handle
        // so the whole scrub is still one live edit and one undo step. An
        // entry already at this opacity answers nil (the core's no-op rule)
        // and is simply skipped.
        var updated = document.doc
        var moved = false
        for target in indices {
            if let next = updated?.withLayerOpacity(target, value) {
                updated = next
                moved = true
            }
        }
        if moved, let updated = updated {
            document.updateLiveEdit(updated)
        }
        if !stillDragging {
            opacityDragActive = false
            document.endLiveEdit(
                "Layer Opacity",
                record: .selectionProperty(
                    "opacity", ActionArgs.number(value), selectionCount: indices.count,
                    note: "Layer Opacity"))
        }
    }
}

// MARK: - Table data source

extension LayersPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let document = document, let doc = document.doc, row >= 0, row < rows.count
        else { return nil }
        var model = rows[row]
        let idx = model.index
        let visible = model.info.visible

        let cell = LayerCellView(frame: .zero)
        let side = Int(model.hasMask ? LayerCellView.pairedThumbSide : LayerCellView.thumbSide)
        // A GROUP has no pixels of its own: asking the core for its
        // thumbnail would composite its whole subtree once per row on every
        // reload, so the cell draws a folder glyph instead.
        // The layer's own pixels: tagged with the document's space, so a
        // wide-gamut layer's thumbnail matches the canvas rather than showing
        // the same numbers read as sRGB.
        if !model.isGroup, let thumb = doc.layerThumbnail(idx, maxSide: side),
           let cgImage = thumb.makeCGImage(in: doc.colorSpace)
        {
            model.thumbnail = NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        if model.hasMask {
            model.maskThumbnail = maskThumbnail(doc, idx, maxSide: side)
        }
        model.paintTarget = paintTarget
        cell.configure(model)
        cell.onSelectTarget = { [weak self] target in
            self?.selectPaintTarget(target, layer: idx)
        }
        cell.onLoadSelection = { [weak self] target, mode in
            self?.onLoadLayerSelection?(idx, target, mode)
        }
        cell.onEditSource = { [weak self] in
            self?.editLayerSource(idx)
        }
        cell.onToggleVisible = { [weak self] in
            guard let document = self?.document else { return }
            document.applyEdit(
                visible ? "Hide Layer" : "Show Layer",
                record: .layerProperty(
                    "visible", !visible, layerNamed: model.info.name,
                    note: "Layers panel: the eye toggle")
            ) {
                $0.withLayerVisible(idx, !visible)
            }
        }
        cell.onToggleExpanded = { [weak self] in
            // Not an undo step, but a real document change: `open` is saved
            // in the .rz record (ImageDocument.setGroupExpanded).
            self?.document?.setGroupExpanded(
                idx, !model.expanded,
                record: .layerProperty(
                    "open", !model.expanded, layerNamed: model.info.name,
                    note: "Layers panel: a group's disclosure triangle"))
        }
        cell.onRename = { [weak self] newName in
            guard let document = self?.document else { return }
            // Named by the layer's OLD name: on replay the layer still
            // carries it, which is exactly what the symbol has to find.
            document.applyEdit(
                "Rename Layer",
                record: .layerProperty(
                    "name", newName, layerNamed: model.info.name,
                    note: "Layers panel: inline rename")
            ) { $0.withLayerName(idx, newName) }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = LayerRowView(frame: .zero)
        // The row model is the source of both, so the row view is right
        // before any cell reaches it — AppKit builds this view first and
        // draws its background whether or not a cell has landed yet.
        guard row >= 0, row < rows.count else { return view }
        view.depth = rows[row].depth
        view.isPrimarySelection = rows[row].isPrimary
        return view
    }

    /// Routes "edit this layer's source" to the editor by layer kind — the
    /// kinds are mutually exclusive (one meta slot). A plain raster layer has
    /// no source to reopen, so its double-click opens Layer Style instead
    /// (Photoshop's gesture); described layers keep their own editors and
    /// reach Layer Style through the row menu. Both the row's double-click
    /// and the thumbnail's own land here.
    func editLayerSource(_ idx: Int) {
        guard let doc = document?.doc else { return }
        if doc.layerIsAdjustment(idx) {
            onAdjustmentEdit?(idx)
        } else if doc.textPayload(idx) != nil {
            onTextEdit?(idx)
        } else if doc.livePhotoPayload(idx) != nil {
            onLivePhotoEdit?(idx)
        } else if doc.shapePayload(idx) != nil {
            onShapeEdit?(idx)
        } else {
            onLayerStyleEdit?(idx)
        }
    }
}
