import AppKit

/// Select > Load Selection…: a channel, the active layer's transparency or
/// mask, or a colour plane of the composite, loaded as the selection with
/// the usual Replace / Add / Subtract / Intersect operation and an Invert
/// checkbox.
///
/// The dialog only chooses; `EditorViewController.loadSelection` does the
/// work, so the sheet, the row menu and the ⌘-click gestures all take the
/// same path (and share its all-zero rule: an empty source deselects, it
/// does not beep).
final class LoadSelectionSheetController: NSViewController {
    private weak var editor: EditorViewController?

    /// Popup item index → the source it loads. A nil entry is a separator
    /// row, which AppKit will not let the user land on; it is kept in the
    /// array so the index is a plain subscript.
    private let sources: [SelectionSource?]
    private let titles: [String]

    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let invertCheckbox = NSButton(
        checkboxWithTitle: "Invert", target: nil, action: nil)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// The 420pt card less its 22pt insets is 376pt; the shared 106pt label
    /// column and the grid's 12pt column spacing leave 258pt for the
    /// control. Capping the popups just under that lets a long channel name
    /// truncate inside the card instead of widening the sheet.
    private static let controlWidth: CGFloat = 250

    init(editor: EditorViewController) {
        self.editor = editor
        let entries = Self.entries(
            doc: editor.document?.doc, activeLayer: editor.document?.activeLayerIndex ?? 0)
        self.titles = entries.map { $0.title }
        self.sources = entries.map { $0.source }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LoadSelectionSheetController does not support NSCoder")
    }

    /// The Source popup, top to bottom: every alpha channel, the active
    /// layer's transparency and (only while it has one) its mask, then the
    /// composite's colour planes. A nil source marks a separator, and the
    /// separator before the channels group is dropped when there are no
    /// channels so the list never opens with a rule.
    private static func entries(
        doc: RasterDocument?, activeLayer: Int
    ) -> [(title: String, source: SelectionSource?)] {
        guard let doc = doc else { return [] }
        var entries: [(title: String, source: SelectionSource?)] = []
        for index in 0..<doc.channelCount {
            let name = doc.channelInfo(index)?.name ?? "Channel \(index + 1)"
            entries.append((name, .channel(index)))
        }
        if !entries.isEmpty {
            entries.append(("", nil))
        }
        entries.append(("Layer Transparency", .layerAlpha(activeLayer)))
        if activeLayer >= 0, activeLayer < doc.layerCount, doc.layerHasMask(activeLayer) {
            entries.append(("Layer Mask", .layerMask(activeLayer)))
        }
        entries.append(("", nil))
        // Luma is read-only everywhere else in the phase; as a SOURCE it is
        // the one plane that answers "how bright is this pixel".
        for plane: RasterPlane in [.red, .green, .blue, .luma] {
            entries.append((plane.displayName, .compositePlane(plane)))
        }
        return entries
    }

    override func loadView() {
        let menu = NSMenu()
        for (index, title) in titles.enumerated() {
            if sources[index] == nil {
                menu.addItem(.separator())
            } else {
                menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        sourcePopup.menu = menu
        if let first = sources.firstIndex(where: { $0 != nil }) {
            sourcePopup.selectItem(at: first)
        }
        sourcePopup.font = DS.sans(13)
        sourcePopup.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.controlWidth).isActive = true

        invertCheckbox.font = DS.sans(13)

        modePopup.addItems(withTitles: SelectionCombineMode.sheetChoices.map { $0.title })
        modePopup.selectItem(at: 0)  // Replace
        modePopup.font = DS.sans(13)
        modePopup.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.controlWidth).isActive = true

        let grid = NSGridView(views: [
            [fieldLabel("Source:"), sourcePopup],
            [NSGridCell.emptyContentView, invertCheckbox],
            [fieldLabel("Operation:"), modePopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let loadButton = StickerButton(
            title: "Load", style: .primary, target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Load selection",
            hint: "Loads a channel, a layer's transparency or mask, or a colour plane as the "
                + "selection. An empty source simply deselects.",
            content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: loadButton,
                leading: [sheetFootnote("no undo step")]))
    }

    @objc private func applyClicked(_ sender: Any?) {
        let index = sourcePopup.indexOfSelectedItem
        guard index >= 0, index < sources.count, let source = sources[index] else {
            NSSound.beep()
            return
        }
        let modeIndex = modePopup.indexOfSelectedItem
        guard modeIndex >= 0, modeIndex < SelectionCombineMode.sheetChoices.count else {
            NSSound.beep()
            return
        }
        let mode = SelectionCombineMode.sheetChoices[modeIndex].mode
        let invert = invertCheckbox.state == .on
        let editor = self.editor
        dismiss(self)
        editor?.loadSelection(from: source, mode: mode, invert: invert)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}
