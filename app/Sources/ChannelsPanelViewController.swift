import AppKit

/// The Channels tab of the right panel: RGB, the three colour planes, the
/// active layer's mask (while it has one), then every alpha channel the
/// document carries. Selecting a row IS the paint target — brush, eraser,
/// fill, gradient, the destructive filters and the adjustments all follow
/// it — and the eye column decides what the canvas draws: the colour
/// composite, one plane in grayscale, and any number of rubylith washes
/// over it.
///
/// Nothing here mutates the document except through the same nil-target
/// actions the Image > Channels menu sends (EditorViewController+Channels):
/// switching tabs, selecting a row and toggling an eye are view state, with
/// no undo step and no dirty flag, exactly like the Layers panel's own
/// selection.
final class ChannelsPanelViewController: NSViewController {
    weak var document: ImageDocument?

    /// Tab switches, mirroring the other three panels.
    var onShowLayers: (() -> Void)?
    var onShowAssistant: (() -> Void)?
    var onShowInfo: (() -> Void)?

    /// The selected row's paint target: the editor makes it the edit target.
    var onSelectTarget: ((PaintTarget) -> Void)?

    /// The eye column changed: the editor rebuilds the canvas's display.
    var onVisibilityChange: ((ChannelVisibility) -> Void)?

    /// ⌘-click on a row (Shift adds, Option subtracts, both intersect):
    /// load that row's plane as the selection. Never an edit.
    var onLoadSelection: ((SelectionSource, SelectionCombineMode) -> Void)?

    /// An alpha row's inline rename committed (the channel's STABLE ID, the
    /// new name). The id, not the row's index: the field editor outlives the
    /// row it was opened on, and any insert, delete or undo in between
    /// renumbers the list under it.
    var onRenameChannel: ((UInt64, String) -> Void)?

    /// The eye column. Owned here, pushed out through `onVisibilityChange`.
    /// Its alpha-row indices are the INDEX VIEW of `visibleChannels` below,
    /// recomputed whenever the channel list changes.
    private(set) var visibility = ChannelVisibility()

    /// Which alpha rows have their eye on, kept by the core's stable channel
    /// ID (`RasterDocument.ChannelInfo.id`) rather than by index or name.
    ///
    /// Deleting a channel, duplicating one (which inserts at i+1) and undoing
    /// any add or delete all RENUMBER the rows below the change. An
    /// index-keyed set survives that renumbering unnoticed, so the eye the
    /// user set on A silently becomes an eye on B — a rubylith over a channel
    /// nobody asked to see, with the one they were watching gone. Names are
    /// no better: they are not unique, and every rename path would drop the
    /// eye. The core's id is neither — it is minted per channel, kept through
    /// a rename, an edit and undo/redo, fresh for a duplicate, and gone with
    /// the channel — so re-resolving the set against the current list
    /// (`resolveChannelVisibility`) makes an eye follow its channel and
    /// disappear with it.
    private var visibleChannels: Set<UInt64> = []

    /// The editor's paint target, mirrored in as the selected row + ring.
    private(set) var paintTarget: PaintTarget = .layer

    /// The row a click just asked to target, held only for the length of that
    /// click: `setPaintTarget` reveals it if — and only if — the editor comes
    /// back having ACCEPTED it as the target (see `revealOnSelect`).
    private var pendingReveal: ChannelRow?

    /// Whether the editor has a selection to save, and whether Quick Mask
    /// holds the selection — pushed in, because the footer's Save and Load
    /// buttons are nil-target actions AppKit never validates.
    private var canSaveSelection = false
    private var quickMaskActive = false

    /// The projection, aspect-fit to thumbnail size ONCE per reload — every
    /// row's thumbnail source. A colour-plane row then extracts its plane
    /// from a 44-pixel image rather than from the full canvas, which is what
    /// keeps a reload off the main thread's back on a large document (the
    /// plane readers allocate a canvas-sized buffer per call).
    private var thumbnailComposite: RasterImage?

    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let rowMenu = NSMenu()
    private var rows: [ChannelRow] = []
    private var loadButton: NSButton!
    private var saveButton: NSButton!
    private var addButton: NSButton!
    private var deleteButton: NSButton!
    private let channelCountLabel = NSTextField(labelWithString: "")

    /// Guards programmatic (re)selection so it never round-trips back out
    /// as a user target change — the Layers panel's pattern.
    private var isReloading = false
    /// A document change that arrived while the tab was hidden; consumed by
    /// setPanelVisible. Regenerating five thumbnails for a panel nobody can
    /// see is the cost this avoids.
    private var needsReload = false

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChannelsPanelViewController does not support NSCoder")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: DS.panelWidth, height: 400))
        root.wantsLayer = true
        root.layer?.backgroundColor = DS.chromeBackground.cgColor

        let tab = PanelTabsView(
            titles: ["Layers", "Channels", "Assistant", "Info"], activeIndex: 1
        ) { [weak self] index in
            if index == 0 { self?.onShowLayers?() }
            if index == 2 { self?.onShowAssistant?() }
            if index == 3 { self?.onShowInfo?() }
        }
        tab.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channel"))
        column.width = DS.panelWidth - 20
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Keyboard focus stays on the canvas, exactly as in the Layers
        // panel: rows select by click, renaming focuses its own field.
        tableView.refusesFirstResponder = true
        tableView.rowHeight = DS.layerRow
        tableView.allowsMultipleSelection = false
        // Unlike the layer list, empty selection IS reachable: `.plane(.alpha)`
        // is a legitimate target (Load Selection, MCP) with no row of its own,
        // and a lie would be worse than no highlight.
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
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

        // Footer: nil targets, so the buttons, the row menu and the
        // Image > Channels / Select menu items share one set of handlers
        // and one set of validation rules.
        loadButton = GhostButton(
            symbol: "dot.circle.and.hand.point.up.left.fill", fallback: "◎", caption: nil,
            tooltip: "Load Channel as Selection",
            action: #selector(EditorViewController.loadChannelAsSelection(_:)))
        saveButton = GhostButton(
            symbol: "square.and.arrow.down", fallback: "⤓", caption: nil,
            tooltip: "Save Selection as Channel",
            action: #selector(EditorViewController.saveSelectionSheet(_:)))
        addButton = GhostButton(
            symbol: "plus", fallback: "+", caption: nil, tooltip: "New Channel",
            action: #selector(EditorViewController.newChannel(_:)))
        deleteButton = GhostButton(
            symbol: "trash", fallback: "✕", caption: nil, tooltip: "Delete Channel",
            action: #selector(EditorViewController.deleteChannel(_:)))

        channelCountLabel.translatesAutoresizingMaskIntoConstraints = false
        channelCountLabel.font = DS.mono(10)
        channelCountLabel.textColor = DS.textFaint
        channelCountLabel.alignment = .right

        let footerSeparator = NSView()
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.wantsLayer = true

        let footerSpacer = NSView()
        let footer = NSStackView(views: [
            loadButton, saveButton, addButton, deleteButton, footerSpacer, channelCountLabel,
        ])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.spacing = 2
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 12)

        root.addSubview(tab)
        root.addSubview(tableScroll)
        root.addSubview(footerSeparator)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            tab.topAnchor.constraint(equalTo: root.topAnchor),
            tab.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tab.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tab.heightAnchor.constraint(equalToConstant: DS.tabHeight),

            tableScroll.topAnchor.constraint(equalTo: tab.bottomAnchor, constant: 10),
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
        footerSeparator.layer?.backgroundColor = DS.border.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentDidChange(_:)),
            name: .imageDocumentImageDidChange, object: document)
        reload()
    }

    @objc private func documentDidChange(_ note: Notification) {
        // Live-edit ticks arrive per mouse event and change nothing
        // structural: rebuilding five plane thumbnails per tick would only
        // burn CPU. The gesture's final non-live post does the reload.
        let isLive = (note.userInfo?["isLive"] as? Bool)
            ?? document?.isLiveEditing
            ?? false
        guard !isLive else { return }
        guard isViewLoaded, !view.isHidden else {
            needsReload = true
            return
        }
        reload()
    }

    /// Called by the editor whenever this tab is shown or hidden; a reload
    /// that was deferred while hidden happens here.
    func setPanelVisible(_ visible: Bool) {
        guard visible, needsReload else { return }
        needsReload = false
        reload()
    }

    /// The active layer is NOT a document change and posts no notification
    /// (the Layers panel calls `onActiveLayerChange` instead), yet the
    /// "<layer> Mask" row is computed from it — so the editor calls this.
    func activeLayerChanged() {
        guard isViewLoaded else { return }
        guard !view.isHidden else {
            needsReload = true
            return
        }
        reload()
    }

    // MARK: - Reload

    func reload() {
        guard isViewLoaded else { return }
        let activeLayer = document?.activeLayerIndex ?? 0
        rows = document?.doc?.channelRows(activeLayer: activeLayer) ?? []
        thumbnailComposite = document?.projection.flatMap {
            RasterDocument.fitted($0, maxSide: Int(LayerCellView.thumbSide))
        }
        // Eyes follow their channel through a delete, a duplicate or an undo,
        // and go away with it — by identity, never by index.
        resolveChannelVisibility()
        let count = document?.doc?.channelCount ?? 0
        isReloading = true
        tableView.reloadData()
        selectRow(for: paintTarget)
        isReloading = false
        channelCountLabel.stringValue = count == 1 ? "1 channel" : "\(count) channels"
        updateButtonStates()
    }

    private func updateButtonStates() {
        let hasChannel = paintTarget.isChannel
        // Load acts on whatever the SELECTED ROW stands for (RGB's alpha, a
        // colour plane, the layer mask, an alpha channel), and never inside
        // Quick Mask — the same two rules `validateChannelItem` gives the menu
        // item and the row menu. The Quick Mask half matters most here: a load
        // ends the session through `ImageCanvasView.setSelection`, which
        // DISCARDS the buffer being painted, and a selection is view state
        // with no undo step to bring it back.
        loadButton.isEnabled = !quickMaskActive && rows.contains { $0.paintTarget == paintTarget }
        deleteButton.isEnabled = hasChannel
        // Save Selection needs a selection, and Quick Mask holds it as a
        // buffer rather than a selection.
        saveButton.isEnabled = document?.doc != nil && canSaveSelection && !quickMaskActive
        addButton.isEnabled = document?.doc != nil
    }

    /// The editor's answers to "is there a selection to save?" and "is Quick
    /// Mask holding it?", mirrored in from `updateStatus` (which already runs
    /// on every selection change and on the Quick Mask toggle) — exactly the
    /// terms `validateChannelItem` applies to Select > Save Selection… and to
    /// Load Channel as Selection, so the footer and the menu items agree.
    ///
    /// Both buttons carry nil-target actions, which AppKit never runs
    /// validation on: the rules have to come in from outside, or the buttons
    /// stay live in states every other surface reports as unavailable.
    func setSelectionState(hasSelection: Bool, quickMask: Bool) {
        guard canSaveSelection != hasSelection || quickMaskActive != quickMask else { return }
        canSaveSelection = hasSelection
        quickMaskActive = quickMask
        guard isViewLoaded else { return }
        updateButtonStates()
    }

    // MARK: - Paint target

    /// Mirrors the editor's target into the row selection and the focus
    /// ring, without a reload (which would re-resample every thumbnail).
    ///
    /// This is also the editor's ANSWER to a row click: the target it
    /// accepted, which may not be the one the row asked for (the current tool
    /// cannot reach a plane, the layer has no mask, the channel has gone).
    /// The click's reveal therefore happens here, on the accepted target, and
    /// never for one the editor refused.
    func setPaintTarget(_ target: PaintTarget) {
        paintTarget = target
        guard isViewLoaded else { return }
        isReloading = true
        selectRow(for: target)
        isReloading = false
        refreshTargetRings()
        updateButtonStates()
        if let pending = pendingReveal, pending.paintTarget == target {
            pendingReveal = nil
            revealOnSelect(pending)
        }
    }

    private func selectRow(for target: PaintTarget) {
        guard let row = rows.firstIndex(where: { $0.paintTarget == target }) else {
            // `.plane(.alpha)` and a stale `.channel` have no row.
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func refreshTargetRings() {
        for row in 0..<tableView.numberOfRows {
            guard
                let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? ChannelCellView
            else { continue }
            cell.setTargetHighlight(rows[row].paintTarget == paintTarget)
        }
    }

    // MARK: - Eyes

    /// Every channel's stable id, in index order.
    private func channelIdentities() -> [UInt64] {
        guard let doc = document?.doc else { return [] }
        return (0..<doc.channelCount).map { doc.channelID($0) }
    }

    /// Re-resolves the eye set against the CURRENT channel list: a channel
    /// that survived keeps its eye wherever it moved to, one that is gone
    /// loses it, and `visibility.channels` comes out holding today's indices.
    ///
    /// A rename needs no special case — the id does not change with the name
    /// — and neither does a delete, a duplicate or an undo: an id is minted
    /// per channel and never re-used, so intersecting is the whole rule.
    ///
    /// The layer-mask eye is re-resolved the same way, against the row: a
    /// layer with no mask has no "<layer> Mask" row to turn the eye off with,
    /// and leaving `mask` set would keep the canvas asking for a mask plane
    /// that no longer exists — a blank canvas with no eye to explain it.
    private func resolveChannelVisibility() {
        let identities = channelIdentities()
        visibleChannels.formIntersection(identities)
        visibility.channels = Set(
            identities.indices.filter { visibleChannels.contains(identities[$0]) })
        let activeLayer = document?.activeLayerIndex ?? 0
        if document?.doc?.layerHasMask(activeLayer) != true {
            visibility.mask = false
        }
    }

    /// The eye column with its alpha rows re-resolved against the current
    /// document — what the editor reads when it rebuilds the canvas display,
    /// so a refresh that beats this panel's own reload to the change
    /// notification still draws the channels the user turned on.
    func resolvedVisibility() -> ChannelVisibility {
        resolveChannelVisibility()
        return visibility
    }

    /// Turns channel `index`'s eye on or off, by identity. A 0 id is the
    /// core's "no such channel" and never enters the set.
    private func setChannelEye(_ index: Int, on: Bool) {
        let identities = channelIdentities()
        guard index >= 0, index < identities.count, identities[index] != 0 else { return }
        if on {
            visibleChannels.insert(identities[index])
        } else {
            visibleChannels.remove(identities[index])
        }
        resolveChannelVisibility()
    }

    private func toggleVisibility(of row: ChannelRow) {
        switch row {
        case .composite:
            visibility.setRGBVisible(!visibility.rgb)
        case .plane(let plane):
            visibility.togglePlane(plane)
        case .layerMask:
            visibility.mask.toggle()
        case .alpha(let index):
            setChannelEye(index, on: !visibility.channels.contains(index))
        }
        refreshEyes()
        onVisibilityChange?(visibility)
    }

    /// Selecting a row also makes it the thing you are LOOKING at
    /// (Photoshop), never turning anything off — that is the eye's job. The
    /// RGB row puts the colour composite back; a colour plane row shows that
    /// plane in grayscale, which is the display half of targeting it (the
    /// edit half still lands on the active layer); a mask or channel row
    /// turns its own rubylith on. `isVisible` reads a plane row as visible
    /// whenever RGB is on, so this deliberately does NOT go through it: a
    /// row you just picked must end up on screen either way.
    ///
    /// Called only once the editor has ACCEPTED the row as the edit target
    /// (`setPaintTarget`). Revealing on the click itself showed a plane the
    /// editor then refused — pick the Clone Stamp, click Red, and the canvas
    /// went grayscale while the coercion put the selection back on RGB,
    /// leaving one eye open on a row nothing was targeting.
    private func revealOnSelect(_ row: ChannelRow) {
        switch row {
        case .composite:
            guard !visibility.rgb else { return }
            visibility.setRGBVisible(true)
        case .plane(let plane):
            guard !visibility.showsPlaneBase || visibility.plane != plane else { return }
            visibility.showPlane(plane)
        case .layerMask:
            guard !visibility.mask else { return }
            visibility.mask = true
        case .alpha(let index):
            guard !visibility.channels.contains(index) else { return }
            setChannelEye(index, on: true)
        }
        refreshEyes()
        onVisibilityChange?(visibility)
    }

    private func refreshEyes() {
        for row in 0..<tableView.numberOfRows {
            guard
                let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? ChannelCellView
            else { continue }
            cell.setVisible(visibility.isVisible(rows[row]))
        }
    }

    // MARK: - Row actions

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        // Only an alpha channel carries a name of its own; the fixed rows
        // are named by what they are.
        guard case .alpha = rows[row] else {
            NSSound.beep()
            return
        }
        beginRename(row: row)
    }

    private func beginRename(row: Int) {
        tableView.scrollRowToVisible(row)
        guard
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? ChannelCellView
        else { return }
        cell.beginRename()
    }

    @objc private func renameClickedChannel(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count, case .alpha = rows[row] else { return }
        beginRename(row: row)
    }

    /// The modifier vocabulary the selection tools use (the one copy lives
    /// on `SelectionCombineMode`), with Replace as the no-modifier base: a
    /// panel click carries no options-bar mode.
    private static func combineMode(for event: NSEvent) -> SelectionCombineMode {
        SelectionCombineMode.from(event.modifierFlags)
    }
}

// MARK: - Table data source / delegate

extension ChannelsPanelViewController: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate
{
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let document = document, let doc = document.doc, row < rows.count else { return nil }
        let channelRow = rows[row]
        let activeLayer = document.activeLayerIndex
        let cell = ChannelCellView(frame: .zero)
        var thumbnail: NSImage? = nil
        // The core does the downsampling (that is what max_side is for) and
        // the composite rows read the projection ALREADY FITTED by reload —
        // no row ever re-flattens the document, and no row extracts a plane
        // at canvas size to show it 44 pixels wide.
        //
        // One space for the whole call, the document's: the composite row IS
        // the picture, and a plane row is that document's channel values
        // replicated into R=G=B, which Photoshop likewise shows through the
        // working space's transfer curve. The alpha-channel and mask rows are
        // coverage rather than colour, but they arrive through this same call
        // as neutral greys, and a neutral stays neutral under any profile we
        // can carry — a differing transfer curve shifts a coverage thumbnail
        // by the same shade it shifts the plane rows beside it, which is the
        // consistency worth having in one well.
        if let image = doc.planeImage(
            for: channelRow, composite: thumbnailComposite, activeLayer: activeLayer,
            maxSide: Int(LayerCellView.thumbSide)),
           let cgImage = image.makeCGImage(in: doc.colorSpace)
        {
            thumbnail = NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        cell.configure(
            row: channelRow, title: Self.title(for: channelRow, doc: doc, activeLayer: activeLayer),
            subtitle: Self.subtitle(for: channelRow, doc: doc),
            thumbnail: thumbnail, visible: visibility.isVisible(channelRow),
            targeted: channelRow.paintTarget == paintTarget)
        cell.onToggleVisible = { [weak self] in self?.toggleVisibility(of: channelRow) }
        cell.onSelect = { [weak self] in
            guard let self = self, let index = self.rows.firstIndex(of: channelRow) else { return }
            self.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        cell.onCommandClick = { [weak self] event in
            guard let self = self else { return }
            self.onLoadSelection?(
                channelRow.selectionSource(activeLayer: activeLayer),
                Self.combineMode(for: event))
        }
        // The channel's stable id, captured with the row: the commit below
        // may arrive after a delete, a duplicate or an undo has renumbered
        // the list, and the id is what still names the channel this field was
        // opened on. 0 (a fixed row, or an index the document no longer has)
        // renames nothing.
        var renameID: UInt64 = 0
        if case .alpha(let index) = channelRow { renameID = doc.channelID(index) }
        cell.onRename = { [weak self] name in
            guard renameID != 0 else { return }
            // The eye follows the new name in `resolveChannelVisibility`,
            // which carries every rename path — this field, the row menu, the
            // options sheet and the agent — rather than only this one.
            self?.onRenameChannel?(renameID, name)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LayerRowView(frame: .zero)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        let channelRow = rows[row]
        paintTarget = channelRow.paintTarget
        refreshTargetRings()
        updateButtonStates()
        // The editor decides what the target actually becomes and calls
        // `setPaintTarget` back synchronously; the reveal rides on that
        // answer, so a refused row never changes what the canvas shows.
        pendingReveal = channelRow
        onSelectTarget?(channelRow.paintTarget)
        pendingReveal = nil
    }

    /// The row menu, built for the row under the cursor and SELECTING it
    /// first — so the menu, the footer and the Image > Channels menu always
    /// act on the same row, under the editor's one set of validation rules.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if case .alpha = rows[row] {
            let rename = NSMenuItem(
                title: "Rename", action: #selector(renameClickedChannel(_:)), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)
            menu.addItem(
                NSMenuItem(
                    title: "Duplicate Channel",
                    action: #selector(EditorViewController.duplicateChannel(_:)),
                    keyEquivalent: ""))
            menu.addItem(
                NSMenuItem(
                    title: "Delete Channel",
                    action: #selector(EditorViewController.deleteChannel(_:)), keyEquivalent: ""))
            menu.addItem(
                NSMenuItem(
                    title: "Channel Options…",
                    action: #selector(EditorViewController.channelOptions(_:)), keyEquivalent: ""))
            menu.addItem(
                NSMenuItem(
                    title: "Invert Channel",
                    action: #selector(EditorViewController.invertChannel(_:)), keyEquivalent: ""))
            menu.addItem(.separator())
        }
        menu.addItem(
            NSMenuItem(
                title: "Load Channel as Selection",
                action: #selector(EditorViewController.loadChannelAsSelection(_:)),
                keyEquivalent: ""))
    }

    /// Row titles: the fixed rows say what they are, an alpha row its name.
    private static func title(
        for row: ChannelRow, doc: RasterDocument, activeLayer: Int
    ) -> String {
        switch row {
        case .composite: return "RGB"
        case .plane(let plane): return plane.displayName
        case .layerMask:
            let name = doc.layerInfo(activeLayer)?.name ?? "Layer"
            return "\(name) Mask"
        case .alpha(let index): return doc.channelInfo(index)?.name ?? "Alpha \(index + 1)"
        }
    }

    /// The mono meta line: what editing this row actually touches. The
    /// display-vs-edit split is worth saying out loud — a colour plane row
    /// SHOWS the composite's plane but EDITS the active layer's.
    private static func subtitle(for row: ChannelRow, doc: RasterDocument) -> String {
        switch row {
        case .composite: return "composite"
        case .plane: return "active layer's plane"
        case .layerMask: return "layer mask"
        case .alpha(let index):
            guard let info = doc.channelInfo(index) else { return "alpha channel" }
            let side = info.colorIndicatesSelected ? "selected" : "masked"
            return "alpha · \(Int((info.opacity * 100).rounded()))% \(side)"
        }
    }
}

// MARK: - ChannelCellView

/// One row of the channels table: 22px eye, a framed grayscale thumbnail,
/// then the row's name over a mono meta line. Built from the Layers panel's
/// own pieces (`ThumbnailWellView`, `ThumbnailImageView`, `LayerRowView`),
/// so the two lists look like one panel.
final class ChannelCellView: NSView, NSTextFieldDelegate {
    private let eyeButton = NSButton(title: "", target: nil, action: nil)
    private let thumbView = ThumbnailImageView()
    private let thumbFrame = ThumbnailWellView()
    private let nameField = NSTextField(string: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var committedName = ""

    var onToggleVisible: (() -> Void)?
    /// A plain click on the thumbnail selects the row (and so retargets).
    var onSelect: (() -> Void)?
    /// ⌘-click on the thumbnail: load this row's plane as the selection.
    var onCommandClick: ((NSEvent) -> Void)?
    /// Only alpha rows are renameable; the fixed rows leave this nil and
    /// their field is not editable.
    var onRename: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        eyeButton.translatesAutoresizingMaskIntoConstraints = false
        eyeButton.isBordered = false
        eyeButton.setButtonType(.momentaryChange)
        eyeButton.target = self
        eyeButton.action = #selector(eyeClicked(_:))

        thumbFrame.translatesAutoresizingMaskIntoConstraints = false
        thumbFrame.wantsLayer = true
        thumbFrame.layer?.cornerRadius = 5
        thumbFrame.layer?.borderWidth = 1
        thumbFrame.layer?.masksToBounds = true
        thumbFrame.onClick = { [weak self] in self?.onSelect?() }
        thumbFrame.onCommandClick = { [weak self] event in self?.onCommandClick?(event) }

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbFrame.addSubview(thumbView)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.font = DS.sans(13)
        nameField.delegate = self

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = DS.mono(10)
        metaLabel.textColor = DS.textFaint
        metaLabel.lineBreakMode = .byTruncatingTail

        addSubview(eyeButton)
        addSubview(thumbFrame)
        addSubview(nameField)
        addSubview(metaLabel)

        NSLayoutConstraint.activate([
            eyeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            eyeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            eyeButton.widthAnchor.constraint(equalToConstant: 22),

            thumbFrame.leadingAnchor.constraint(
                equalTo: eyeButton.trailingAnchor, constant: 9),
            thumbFrame.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbFrame.widthAnchor.constraint(equalToConstant: LayerCellView.thumbSide),
            thumbFrame.heightAnchor.constraint(equalToConstant: LayerCellView.thumbSide),

            thumbView.topAnchor.constraint(equalTo: thumbFrame.topAnchor),
            thumbView.bottomAnchor.constraint(equalTo: thumbFrame.bottomAnchor),
            thumbView.leadingAnchor.constraint(equalTo: thumbFrame.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: thumbFrame.trailingAnchor),

            nameField.leadingAnchor.constraint(equalTo: thumbFrame.trailingAnchor, constant: 9),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            nameField.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            metaLabel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChannelCellView does not support NSCoder")
    }

    /// ⌘-click anywhere in the row loads it as a selection, not just on the
    /// thumbnail: the editable name field would otherwise swallow the click
    /// into a rename and the eye into a visibility toggle. Hit testing has
    /// only the CURRENT modifier state to go on — which is exactly the state
    /// the click about to be delivered carries.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil, onCommandClick != nil, NSEvent.modifierFlags.contains(.command)
        else { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onCommandClick = onCommandClick else {
            // Everything else belongs to the table view: row selection, the
            // double-click rename, the row menu.
            super.mouseDown(with: event)
            return
        }
        onCommandClick(event)
    }

    func configure(
        row: ChannelRow, title: String, subtitle: String, thumbnail: NSImage?, visible: Bool,
        targeted: Bool
    ) {
        committedName = title
        nameField.stringValue = title
        nameField.font = DS.sans(13, weight: targeted ? .semibold : .regular)
        nameField.textColor = targeted ? DS.accent : DS.textStrong
        if case .alpha = row {
            nameField.isEditable = true
        } else {
            nameField.isEditable = false
        }
        metaLabel.stringValue = subtitle
        thumbView.image = thumbnail
        switch row {
        case .composite:
            thumbFrame.toolTip = "Edit the layer's pixels"
        case .plane(let plane):
            thumbFrame.toolTip =
                "Paint and filter the active layer's \(plane.displayName.lowercased()) plane "
                + "(the canvas shows the composite's). ⌘-click loads it as a selection."
        case .layerMask:
            thumbFrame.toolTip = "Paint the active layer's mask. ⌘-click loads it as a selection."
        case .alpha:
            thumbFrame.toolTip =
                "Paint this alpha channel. ⌘-click loads it as a selection "
                + "(Shift adds, Option subtracts)."
        }
        setVisible(visible)
        setTargetHighlight(targeted)
    }

    func setVisible(_ visible: Bool) {
        let symbol = visible ? "eye" : "eye.slash"
        let label = visible ? "Visible" : "Hidden"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            eyeButton.image = image.tinted(with: visible ? DS.textMuted : DS.textFaint)
            eyeButton.title = ""
        } else {
            eyeButton.image = nil
            eyeButton.title = visible ? "●" : "○"
        }
        eyeButton.toolTip = visible ? "Hide" : "Show"
    }

    /// Rings the thumbnail the edit target currently points at — the
    /// channels twin of the layers panel's paint-target ring.
    func setTargetHighlight(_ targeted: Bool) {
        thumbFrame.layer?.borderWidth = targeted ? 2 : 1
        thumbFrame.layer?.borderColor = (targeted ? DS.accent : DS.border).cgColor
    }

    func beginRename() {
        guard nameField.isEditable, window?.makeFirstResponder(nameField) == true else { return }
        nameField.currentEditor()?.selectAll(nil)
    }

    @objc private func eyeClicked(_ sender: Any?) {
        onToggleVisible?()
    }

    /// Commits the inline rename, reverting to the committed name when the
    /// field holds nothing usable.
    ///
    /// Trimmed before the emptiness test: a channel named " " draws as a
    /// blank row this very field cannot commit again, and could only ever be
    /// addressed by index — which is why the agent's `rename_channel` refuses
    /// a whitespace-only name and `set_channel_options` quietly keeps the old
    /// one. The UI must not create the state its own agent surface is written
    /// to prevent.
    func controlTextDidEndEditing(_ obj: Notification) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            nameField.stringValue = committedName
        } else if name != committedName {
            onRename?(name)
        }
    }
}
