import AppKit

/// Tools ▸ Command Palette… (⇧⌘K) — fuzzy-search every enabled menu command
/// and run it.
///
/// ⇧⌘K rather than the ⌘K the brief names: **⌘K is Crop**, and the app's
/// standing rule is that a shortcut already in the user's fingers is never
/// silently renegotiated.
///
/// The list is a fresh walk of `NSApp.mainMenu` on every open
/// (`CommandPalette.commands`), scored by a pure function
/// (`CommandPalette.matches`), and run through `NSApp.sendAction` — so a
/// command reached through the palette behaves EXACTLY as it does from the
/// menu, including being recorded into an Action. The palette is a way to
/// reach a command, not a way to replay one, which is why `ActionRecorder`
/// is never suspended around it.
///
/// **Not modal, and not a sheet.** A modal palette could not run the command
/// it just picked (the pick's own sheet or alert would be blocked behind the
/// modal session), and there is no window to hang a sheet from when nothing
/// is open — the palette has to work with no document, so that `File ▸ Open…`
/// is reachable from it.
final class CommandPaletteWindowController: NSWindowController {
    static let shared = CommandPaletteWindowController()

    /// The fixed chrome around the list, in points. Every number here is
    /// spent once, in `place()`, to size the window to its rows.
    private enum Metrics {
        static let width: CGFloat = 540
        static let inset: CGFloat = 14
        /// `DSField.style`'s own height — restated, not re-derived, because
        /// the window's height is arithmetic over these and a guess would
        /// leave a gap.
        static let fieldHeight: CGFloat = 26
        static let gap: CGFloat = 10
        static let hintHeight: CGFloat = 15
        static let bottom: CGFloat = 10
        /// Two lines of text (title over path) plus breathing room.
        static let rowHeight: CGFloat = 38
        /// The list scrolls past this. Eight rows is a glance; the matcher
        /// still returns up to `CommandPalette.maxRows` and the rest are one
        /// scroll away.
        static let visibleRows = 8
        /// Everything but the list.
        static let chrome = inset + fieldHeight + gap + gap + hintHeight + bottom
        /// How far down the reference frame the palette's top edge sits. A
        /// palette belongs in the upper third, where the eye already is.
        static let topFraction: CGFloat = 0.18
    }

    private static let hintText = "Only commands that can run right now are listed."

    private let field = NSTextField()
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: CommandPaletteWindowController.hintText)

    /// The whole enabled menu, walked when the palette opened.
    private var commands: [CommandPaletteItem] = []
    /// What the current query matched, in the order they are listed.
    private var rows: [CommandPaletteItem] = []

    private init() {
        // A borderless PANEL. Borderless because a palette is one card and a
        // title bar would be a second thing to look at — and a transparent
        // title bar is not the cheaper route: with `.titled` the title-bar
        // view still sits over the content and takes the clicks in that
        // band, so the query field under it would drag the window instead of
        // placing the caret. A panel rather than a window because a panel
        // cannot become MAIN: the document window stays main while the
        // palette is key, which is what keeps menu validation answering
        // about the document.
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        // Not shown anywhere, but it is what VoiceOver and the window list
        // read.
        panel.title = "Command Palette"
        panel.isFloatingPanel = true
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .utilityWindow
        // The card's rounded corners are drawn by the content view's layer,
        // so the window itself must not paint a square one behind them.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CommandPaletteWindowController does not support NSCoder")
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 200))
        container.wantsLayer = true
        // The card itself: the window is clear and borderless, so this layer
        // is the whole visible surface. `masksToBounds` is what keeps the
        // list's rows inside the rounded corners.
        container.layer?.backgroundColor = DS.chromeBackground.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = DS.border.cgColor

        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Run a command…"
        field.delegate = self
        // The panel IS the focus; a ring inside it is noise.
        field.focusRingType = .none
        DSField.style(field)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Metrics.rowHeight
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        // The query field keeps the keyboard: ↑/↓ move the selection from
        // there, so the table must never take focus away from it.
        tableView.refusesFirstResponder = true
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        // ONE click runs, the way every palette behaves: the row under the
        // pointer is the row the reader has already chosen.
        tableView.action = #selector(rowClicked(_:))

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = DS.sans(11)
        hint.textColor = DS.textFaint
        hint.lineBreakMode = .byTruncatingTail

        container.addSubview(field)
        container.addSubview(scroll)
        container.addSubview(hint)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.inset),
            field.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Metrics.inset),
            field.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Metrics.inset),

            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Metrics.gap),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Metrics.gap),
            hint.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Metrics.inset),
            hint.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Metrics.inset),
            hint.heightAnchor.constraint(equalToConstant: Metrics.hintHeight),
            hint.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -Metrics.bottom),
        ])
        return container
    }

    /// Sizes the window to the rows it has and, the first time, puts it in
    /// the upper third of the window it was invoked from.
    ///
    /// The TOP edge is what stays put while the list grows and shrinks: a
    /// palette that moved its query field on every keystroke would be
    /// unusable.
    private func place() {
        guard let window = window else { return }
        let visible = min(rows.count, Metrics.visibleRows)
        scroll.isHidden = visible == 0
        let height = Metrics.chrome + CGFloat(visible) * Metrics.rowHeight
        if window.isVisible {
            var frame = window.frame
            let top = frame.maxY
            frame.size.height = height
            frame.origin.y = top - height
            window.setFrame(frame, display: true)
            return
        }
        let reference =
            (NSApp.keyWindow ?? NSApp.mainWindow)?.frame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = (reference.midX - Metrics.width / 2).rounded()
        var top = reference.maxY - reference.height * Metrics.topFraction
        // Keep the whole card on the screen the reference sits on — a palette
        // half off the edge is worse than one slightly out of place.
        let screen =
            NSScreen.screens.first { $0.frame.intersects(reference) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        if let screen = screen {
            x = min(max(x, screen.minX + 8), max(screen.maxX - Metrics.width - 8, screen.minX + 8))
            top = min(max(top, screen.minY + height + 8), screen.maxY - 8)
        }
        window.setFrame(
            NSRect(x: x, y: top - height, width: Metrics.width, height: height), display: false)
    }

    // MARK: - Showing

    /// Brings the palette up over the frontmost window with an empty query.
    ///
    /// The menu is walked BEFORE the panel takes key, so every item is
    /// validated against the document window's own responder chain — the
    /// state the reader is looking at. (Re-invoking ⇧⌘K while the palette is
    /// already key re-walks with the palette key; a panel cannot become main,
    /// so `NSApp.targetForAction` still reaches the editor through the main
    /// window and the answers are the same.)
    func show() {
        guard let window = window else { return }
        applyCardColors()
        commands = CommandPalette.commands()
        field.stringValue = ""
        reload()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    /// A `CGColor` is resolved against the appearance in force when it is
    /// read, and this window is long-lived — so the card's colours are
    /// re-read on every open rather than once at init, the way the welcome
    /// window re-applies its background.
    private func applyCardColors() {
        guard let layer = window?.contentView?.layer else { return }
        layer.backgroundColor = DS.chromeBackground.cgColor
        layer.borderColor = DS.border.cgColor
    }

    private func reload() {
        rows = CommandPalette.matches(for: field.stringValue, in: commands)
        tableView.reloadData()
        if rows.isEmpty {
            let query = field.stringValue.trimmingCharacters(in: .whitespaces)
            hint.stringValue =
                query.isEmpty
                ? "No command can run right now." : "No command matches “\(query)”."
        } else {
            hint.stringValue = Self.hintText
        }
        select(0)
        place()
    }

    private func select(_ index: Int) {
        guard !rows.isEmpty else { return }
        let clamped = min(max(index, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    private func dismiss() {
        // orderOut, never close: the palette is a shared singleton that comes
        // back, and ordering out hands key back to the window underneath.
        window?.orderOut(nil)
    }

    // MARK: - Running

    @objc private func rowClicked(_ sender: Any?) {
        let clicked = tableView.clickedRow
        guard clicked >= 0, clicked < rows.count else { return }
        run(rows[clicked])
    }

    private func runSelected() {
        let selected = tableView.selectedRow
        guard selected >= 0, selected < rows.count else {
            NSSound.beep()
            return
        }
        run(rows[selected])
    }

    /// Runs one command exactly as the menu would.
    ///
    /// The palette is dismissed FIRST, for two reasons that both bite: the
    /// document window has to be key again before a command puts up a sheet
    /// or reads the first responder, and a palette still floating over the
    /// alert its own pick raised would be in the way of the answer.
    ///
    /// `sendAction(_:to:from:)` with the item's own target — nil for every
    /// item this app builds — walks the responder chain the menu walks, so
    /// the command reaches the same handler, records the same Action step
    /// and registers the same undo entry as it does from the menu bar.
    private func run(_ item: CommandPaletteItem) {
        guard let action = item.action else {
            NSSound.beep()
            return
        }
        dismiss()
        if !NSApp.sendAction(action, to: item.target, from: item.menuItem) {
            // Nothing in the chain answered — the state changed between the
            // walk and the pick (the document closed under it, say).
            NSSound.beep()
        }
    }
}

// MARK: - Query field

extension CommandPaletteWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    /// The four keys a palette owns. Everything else — typing, ⌘A, the
    /// arrows inside the text — is left to the field editor.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            select(tableView.selectedRow - 1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            select(tableView.selectedRow + 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            runSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }
}

// MARK: - The list

extension CommandPaletteWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < rows.count else { return nil }
        let cell = CommandPaletteRowCellView(frame: .zero)
        cell.configure(rows[row])
        return cell
    }

    /// The layers panel's row view, for its selection treatment: the accent
    /// ring and fill the rest of the app draws, rather than the system's
    /// inverting highlight (which would fight the row's own faint path line).
    /// Depth 0 draws no nesting guides.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LayerRowView(frame: .zero)
    }
}

// MARK: - Dismissal

extension CommandPaletteWindowController: NSWindowDelegate {
    /// A palette that lost the keyboard has been abandoned — clicking the
    /// document behind it is a dismissal, not a background palette.
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}

// MARK: - The panel

/// The palette's window. It exists for one override: a `.borderless` window
/// refuses key status unless it says otherwise, and a palette that cannot
/// take the keyboard is not a palette.
private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - One row

/// One command in the list: what it is called, where it lives, and what it
/// answers to on the keyboard.
private final class CommandPaletteRowCellView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = DS.sans(13)
        title.textColor = DS.textStrong
        title.lineBreakMode = .byTruncatingTail
        path.font = DS.mono(10)
        path.textColor = DS.textFaint
        path.lineBreakMode = .byTruncatingHead
        shortcut.font = DS.mono(11)
        shortcut.textColor = DS.textMuted
        shortcut.alignment = .right
        for label in [title, path, shortcut] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        // The shortcut column never gives way; the two text lines truncate.
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            // 12pt in from the row's edge clears LayerRowView's 6pt selection
            // inset with a hair to spare.
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            title.trailingAnchor.constraint(
                lessThanOrEqualTo: shortcut.leadingAnchor, constant: -8),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            path.trailingAnchor.constraint(
                lessThanOrEqualTo: shortcut.leadingAnchor, constant: -8),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CommandPaletteRowCellView does not support NSCoder")
    }

    func configure(_ item: CommandPaletteItem) {
        title.stringValue = item.title
        path.stringValue = item.path
        shortcut.stringValue = item.shortcut
    }
}
