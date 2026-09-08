import AppKit

/// Select > Save Selection…: writes the current selection into a new alpha
/// channel, or combines it into an existing one under the same four-way
/// algebra Load Selection uses.
///
/// The dialog only chooses; `EditorViewController.saveSelection` makes the
/// edit, so the whole thing is one undo step either way.
final class SaveSelectionSheetController: NSViewController {
    /// Which row of the Destination popup is which. A separator is a nil
    /// entry in `destinations`, kept so the popup index is a subscript.
    private enum Destination {
        case newChannel
        case existing(Int)
    }

    private weak var editor: EditorViewController?

    private let destinations: [Destination?]
    private let titles: [String]
    /// The name a new channel takes when the field is left empty — the
    /// document's next free "Alpha n" at the moment the sheet opened.
    private let defaultName: String

    private let destinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(string: "")
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// The same 250pt cap the Load sheet uses: the 420pt card less its
    /// insets, the 106pt label column and the grid's column spacing leave
    /// 258pt, so a long channel name truncates rather than widening the
    /// card. The name field matches Channel Options' 220pt field.
    private static let controlWidth: CGFloat = 250
    private static let nameWidth: CGFloat = 220

    init(editor: EditorViewController) {
        self.editor = editor
        let doc = editor.document?.doc
        var titles = ["New Channel"]
        var destinations: [Destination?] = [.newChannel]
        if let doc = doc, doc.channelCount > 0 {
            titles.append("")
            destinations.append(nil)
            for index in 0..<doc.channelCount {
                titles.append(doc.channelInfo(index)?.name ?? "Channel \(index + 1)")
                destinations.append(.existing(index))
            }
        }
        self.titles = titles
        self.destinations = destinations
        self.defaultName = doc?.nextChannelName ?? "Alpha 1"
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SaveSelectionSheetController does not support NSCoder")
    }

    override func loadView() {
        let menu = NSMenu()
        for (index, title) in titles.enumerated() {
            if destinations[index] == nil {
                menu.addItem(.separator())
            } else {
                menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        destinationPopup.menu = menu
        destinationPopup.selectItem(at: 0)  // New Channel
        destinationPopup.font = DS.sans(13)
        destinationPopup.target = self
        destinationPopup.action = #selector(destinationChanged(_:))
        destinationPopup.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.controlWidth).isActive = true

        nameField.stringValue = defaultName
        nameField.widthAnchor.constraint(equalToConstant: Self.nameWidth).isActive = true
        DSField.style(nameField)

        modePopup.addItems(withTitles: SelectionCombineMode.sheetChoices.map { $0.title })
        modePopup.selectItem(at: 0)  // Replace
        modePopup.font = DS.sans(13)
        modePopup.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.controlWidth).isActive = true

        let grid = NSGridView(views: [
            [fieldLabel("Destination:"), destinationPopup],
            [fieldLabel("Name:"), nameField],
            [fieldLabel("Operation:"), modePopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        syncEnabled()

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let saveButton = StickerButton(
            title: "Save", style: .primary, target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Save selection",
            hint: "Writes the current selection into an alpha channel. An existing channel "
                + "combines with it under the operation below; a new one takes it as it is.",
            content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: saveButton,
                leading: [sheetFootnote("one undo step")]))
    }

    /// The name belongs to a new channel and the operation to an existing
    /// one; each is disabled where it would mean nothing.
    private func syncEnabled() {
        var isNew = true
        let index = destinationPopup.indexOfSelectedItem
        if index >= 0, index < destinations.count, case .existing = destinations[index] {
            isNew = false
        }
        nameField.isEnabled = isNew
        nameField.textColor = isNew ? DS.textStrong : DS.textMuted
        modePopup.isEnabled = !isNew
    }

    @objc private func destinationChanged(_ sender: Any?) {
        syncEnabled()
    }

    @objc private func applyClicked(_ sender: Any?) {
        let index = destinationPopup.indexOfSelectedItem
        guard index >= 0, index < destinations.count, let destination = destinations[index] else {
            NSSound.beep()
            return
        }
        let editor = self.editor
        switch destination {
        case .newChannel:
            // An empty (or all-blank) field is not an error: it means "the
            // obvious name", which is the Alpha n the field was prefilled
            // with — recomputed nowhere, so two saves never collide.
            let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = typed.isEmpty ? defaultName : typed
            dismiss(self)
            editor?.saveSelection(to: .newChannel(name), mode: .replace)
        case .existing(let channel):
            let modeIndex = modePopup.indexOfSelectedItem
            guard modeIndex >= 0, modeIndex < SelectionCombineMode.sheetChoices.count else {
                NSSound.beep()
                return
            }
            let mode = SelectionCombineMode.sheetChoices[modeIndex].mode
            dismiss(self)
            editor?.saveSelection(to: .channel(channel), mode: mode)
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}
