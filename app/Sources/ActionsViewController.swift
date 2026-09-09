import AppKit

/// The Actions window's content: the library on top, one action's steps
/// below, and the commands that act on either.
///
/// **What it shows** is one SUBJECT at a time, chosen in the popup: a saved
/// action, the live (or just-stopped) recording, or a file that would not
/// parse — which is listed with `Action.decode`'s own reason rather than
/// dropped, because a user who hand-edits an action has to be able to see
/// what they broke, and Edit JSON is how they fix it in place.
///
/// **How its commands are wired.** The footer's buttons are `GhostButton`s,
/// which carry NIL targets by construction, so the buttons, the row menu and
/// File ▸ Automate all resolve to one set of handlers through the responder
/// chain — Record/Stop lands on `AppDelegate.toggleActionRecording`, the
/// rest land here. Two consequences are written down where they bite:
/// `updateButtonStates` pushes enablement in, because AppKit never runs
/// validation on a nil-target button; and `ActionsWindowController.show`
/// makes THIS controller the window's first responder, because a window
/// whose first responder is the window itself has a chain of
/// `NSWindow → NSWindowController` (measured) that skips the content view
/// controller entirely — and the step table deliberately refuses first
/// responder.
final class ActionsViewController: NSViewController, NSUserInterfaceValidations {
    /// What the step list is showing.
    private enum Subject {
        case none
        /// The recorder's own steps. `live` is true while recording is on.
        case recording(live: Bool)
        /// A saved action, by SUMMARY: the pop-up holds one of these per file
        /// and the window decodes only the selected one (`loaded`).
        case action(url: URL, summary: ActionSummary)
        case broken(file: String, reason: String)
    }

    private var entries: [Subject] = []
    private var subject: Subject = .none

    /// The full decode of the `.action` subject — the ONE action this window
    /// ever holds steps for. Refreshed by `rebuildPopup` whenever the subject
    /// is a saved action, through `ActionLibrary.action(at:)`, whose single
    /// slot makes the repeat asks a reload performs free.
    private var loaded: Action?

    /// Why the selected action's steps could not be read, when its file
    /// summarised cleanly but did not decode — a malformed symbol, a
    /// non-finite number. Shown where a broken file's reason is shown, which
    /// is what keeps "see what you broke, and where" true now that the
    /// listing no longer walks arguments.
    private var loadFailure: String?
    /// Which entry to re-select after a reload, by a stable key rather than
    /// by index: saving, deleting or recording a step all renumber the list.
    private var selectedKey = ""
    /// The row to leave selected after the next reload; -1 deselects, nil
    /// keeps whatever the table has.
    private var pendingStepSelection: Int?
    /// Guards the popup's own action against the programmatic selection a
    /// reload makes — the panels' idiom.
    private var isReloading = false
    /// Latched so a recording that has just STARTED pulls the window onto
    /// itself, while a user who then browses to another action is left
    /// alone.
    private var wasRecording = false
    /// The last run's report (or a save/delete outcome), shown in the status
    /// line until the subject changes.
    private var statusOverride: String?

    private let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let rowMenu = NSMenu()
    private var recordButton: NSButton!
    private var stopButton: NSButton!
    private var saveRecordingButton: NSButton!
    private var playButton: NSButton!
    private var newButton: NSButton!
    private var duplicateButton: NSButton!
    private var deleteButton: NSButton!
    private var editJSONButton: NSButton!

    /// The dragged-row pasteboard type, private to this table — the simple
    /// half of the Layers panel's reorder pattern.
    private static let stepRowType = NSPasteboard.PasteboardType(
        "com.kgalligan.rasterize.actionsteprow")

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ActionsViewController does not support NSCoder")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The controller holds first responder in its own window so nil-target
    /// buttons reach it (see the class comment).
    override var acceptsFirstResponder: Bool { true }

    // MARK: - View construction

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 560))
        root.wantsLayer = true
        root.layer?.backgroundColor = DS.chromeBackground.cgColor

        actionPopup.translatesAutoresizingMaskIntoConstraints = false
        actionPopup.font = DS.sans(13)
        actionPopup.target = self
        actionPopup.action = #selector(actionChosen(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("step"))
        // The starting width — the window's own content width less the
        // scroller — with `.autoresizingMask` keeping the one column filling
        // the table as the window is resized, exactly as the panels' single
        // columns do.
        column.width = 504
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = DS.layerRow
        // The panels' rule, and here it is also what keeps THIS controller
        // the window's first responder, which is what makes the nil-target
        // footer buttons resolve.
        tableView.refusesFirstResponder = true
        // One step at a time: every row command in the menu is singular, and
        // a single selection keeps the drag a one-row move.
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.stepRowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        rowMenu.delegate = self
        tableView.menu = rowMenu

        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = DS.sans(13)
        messageLabel.textColor = DS.textMuted
        messageLabel.isEditable = false
        messageLabel.isHidden = true

        recordButton = GhostButton(
            symbol: "record.circle", fallback: "●", caption: nil, tooltip: "Start Recording",
            action: #selector(AppDelegate.toggleActionRecording(_:)))
        stopButton = GhostButton(
            symbol: "stop.circle", fallback: "■", caption: nil, tooltip: "Stop Recording",
            action: #selector(AppDelegate.toggleActionRecording(_:)))
        saveRecordingButton = GhostButton(
            symbol: "square.and.arrow.down", fallback: "⤓", caption: nil,
            tooltip: "Save Recording as an Action…", action: #selector(saveRecording(_:)))
        playButton = GhostButton(
            symbol: "play.fill", fallback: "▶", caption: nil,
            tooltip: "Play on the front document", action: #selector(playSelectedAction(_:)))
        newButton = GhostButton(
            symbol: "plus", fallback: "+", caption: nil, tooltip: "New Action…",
            action: #selector(newAction(_:)))
        duplicateButton = GhostButton(
            symbol: "plus.square.on.square", fallback: "⧉", caption: nil,
            tooltip: "Duplicate Action", action: #selector(duplicateSelectedAction(_:)))
        deleteButton = GhostButton(
            symbol: "trash", fallback: "✕", caption: nil, tooltip: "Delete Action",
            action: #selector(deleteSelectedAction(_:)))
        editJSONButton = GhostButton(
            symbol: "curlybraces", fallback: "{}", caption: nil, tooltip: "Edit JSON…",
            action: #selector(editActionJSON(_:)))

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = DS.mono(10)
        statusLabel.textColor = DS.textFaint
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail

        let footerSeparator = NSView()
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.wantsLayer = true

        let footerSpacer = NSView()
        let footer = NSStackView(views: [
            recordButton, stopButton, saveRecordingButton, playButton, newButton,
            duplicateButton, deleteButton, editJSONButton, footerSpacer, statusLabel,
        ])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.spacing = 2
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 12)

        root.addSubview(actionPopup)
        root.addSubview(tableScroll)
        root.addSubview(messageLabel)
        root.addSubview(footerSeparator)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            actionPopup.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            actionPopup.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            actionPopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            tableScroll.topAnchor.constraint(equalTo: actionPopup.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            messageLabel.topAnchor.constraint(equalTo: tableScroll.topAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

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
        for name in [ActionLibrary.didChange, ActionRecorder.didChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(libraryDidChange(_:)), name: name, object: nil)
        }
        // Play needs a document, and documents come and go while this window
        // sits open; coming back to the window is the moment to re-ask.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        reload()
    }

    @objc private func libraryDidChange(_ note: Notification) {
        reload()
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === view.window else { return }
        updateButtonStates()
    }

    // MARK: - Reload

    /// Rebuilds the library list, the step table and every enablement rule.
    /// Cheap enough to run on any change: the folder holds a handful of
    /// small JSON files, and the table is one action's steps.
    func reload() {
        guard isViewLoaded else { return }
        let recorder = ActionRecorder.shared
        entries = buildEntries()
        // A recording that has just STARTED takes the window with it — that
        // is the workflow (start, edit, watch the steps land) — but a user
        // who has since browsed to another action keeps their place.
        if recorder.isRecording, !wasRecording { selectedKey = Self.recordingKey }
        wasRecording = recorder.isRecording

        let previousRow = pendingStepSelection ?? tableView.selectedRow
        pendingStepSelection = nil

        // Everything programmatic happens inside the guard: neither the
        // popup's own action nor the table's selection notification may
        // round-trip back out of a reload as if the user had done it.
        isReloading = true
        rebuildPopup()
        tableView.reloadData()
        let count = subjectSteps.count
        if previousRow >= 0, previousRow < count {
            tableView.selectRowIndexes(IndexSet(integer: previousRow), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isReloading = false
        // While a recording grows, keep the newest step in view.
        if case .recording(true) = subject, count > 0 {
            tableView.scrollRowToVisible(count - 1)
        }
        updateMessage()
        updateStatus()
        updateButtonStates()
    }

    private func buildEntries() -> [Subject] {
        var entries: [Subject] = []
        let recorder = ActionRecorder.shared
        // The recording is an entry only while it exists: during a session,
        // and after Stop until it is saved or discarded.
        if recorder.isRecording || !recorder.steps.isEmpty {
            entries.append(.recording(live: recorder.isRecording))
        }
        // Summaries: the pop-up needs names and counts, and this runs on
        // every recorded step (ActionRecorder.didChange reloads us).
        var library: [Subject] = []
        for (url, result) in ActionLibrary.entries() {
            switch result {
            case .ok(let summary): library.append(.action(url: url, summary: summary))
            case .broken(let file, let reason): library.append(.broken(file: file, reason: reason))
            }
        }
        entries.append(contentsOf: library.sorted(by: Self.precedes))
        return entries
    }

    /// The pop-up's order, which is `ActionLibrary.summaries()`'s: valid
    /// actions by display name, then broken files by file name. It is
    /// restated here because the window builds from `ActionLibrary.entries()`
    /// — directory order — so that every row keeps the URL its steps are read
    /// from, and a hand-edit that gives two files one name still picks the
    /// right file.
    private static func precedes(_ a: Subject, _ b: Subject) -> Bool {
        switch (a, b) {
        case (.action(_, let x), .action(_, let y)):
            return x.name.localizedStandardCompare(y.name) == .orderedAscending
        case (.action, .broken): return true
        case (.broken, .action): return false
        case (.broken(let x, _), .broken(let y, _)):
            return x.localizedStandardCompare(y) == .orderedAscending
        default: return false
        }
    }

    private func rebuildPopup() {
        actionPopup.removeAllItems()
        for entry in entries {
            actionPopup.addItem(withTitle: Self.title(for: entry))
            // Two actions may legitimately share a display name only through
            // a hand-edit; `representedObject` is not needed because the
            // index IS the key into `entries`.
            actionPopup.lastItem?.toolTip = Self.tooltip(for: entry)
        }
        actionPopup.isEnabled = !entries.isEmpty
        let index = entries.firstIndex { Self.key(for: $0) == selectedKey } ?? 0
        if entries.indices.contains(index) {
            actionPopup.selectItem(at: index)
            subject = entries[index]
        } else {
            subject = .none
        }
        selectedKey = Self.key(for: subject)
        loadSubjectSteps()
    }

    /// Reads the selected action's steps, and only its own. A reload happens
    /// on every recorded step, so this is asked constantly — and answered
    /// from `ActionLibrary`'s single decoded slot every time but the first
    /// after the file changes.
    private func loadSubjectSteps() {
        loaded = nil
        loadFailure = nil
        guard case .action(let url, _) = subject else { return }
        switch ActionLibrary.action(at: url) {
        case .ok(let action): loaded = action
        case .broken(let file, let reason): loadFailure = "\(file): \(reason)"
        }
    }

    @objc private func actionChosen(_ sender: Any?) {
        guard !isReloading else { return }
        let index = actionPopup.indexOfSelectedItem
        guard entries.indices.contains(index) else { return }
        selectedKey = Self.key(for: entries[index])
        // A new subject starts with no row selected and no stale report.
        pendingStepSelection = -1
        statusOverride = nil
        reload()
    }

    private func updateMessage() {
        let text: String
        switch subject {
        case .none:
            text = """
                No actions yet.

                Record one with File ▸ Automate ▸ Start Recording, or ask the assistant to \
                write one. Actions are JSON files in:
                \(ActionLibrary.directory.path)
                """
        case .broken(let file, let reason):
            text = """
                \(file) could not be read: \(reason)

                Edit JSON to repair it — the file is left exactly as it is until then.
                """
        case .recording, .action:
            // A selected action whose steps would not decode says so here,
            // in the same place and the same words a broken FILE does: the
            // listing no longer walks arguments, so this is where a bad
            // symbol or a non-finite number becomes visible — naming the step
            // and the argument path, which the pop-up never could.
            if let failure = loadFailure {
                text = """
                    \(failure)

                    Edit JSON to repair it — the file is left exactly as it is until then.
                    """
            } else {
                text = subjectSteps.isEmpty
                    ? "No steps yet. Record some, or write them with Edit JSON." : ""
            }
        }
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        tableScroll.isHidden = !text.isEmpty
    }

    private func updateStatus() {
        if let override = statusOverride {
            statusLabel.stringValue = override
            statusLabel.toolTip = override
            return
        }
        var parts: [String] = []
        let steps = subjectSteps
        switch subject {
        case .none, .broken:
            break
        case .recording(let live):
            parts.append(live ? "recording" : "not saved yet")
            parts.append(Self.stepCount(steps.count))
        case .action(_, let summary):
            // From the SUMMARY, not from the decoded steps: the counts are
            // the file's own and are known without reading a step.
            parts.append(Self.stepCount(summary.stepCount))
            if summary.disabledSteps > 0 { parts.append("\(summary.disabledSteps) disabled") }
            if let canvas = summary.recordedCanvas {
                parts.append("recorded at \(canvas.width) × \(canvas.height)")
            }
            if let raw = summary.raw, !raw.isAsShot { parts.append("RAW develop set") }
        }
        let line = parts.joined(separator: " · ")
        statusLabel.stringValue = line
        statusLabel.toolTip = line.isEmpty ? nil : line
    }

    /// Enablement, pushed in: AppKit never validates a nil-target button, so
    /// every rule the row menu states in `validateUserInterfaceItem` has to
    /// be restated here or the footer stays live in states the menu reports
    /// as unavailable.
    private func updateButtonStates() {
        let recorder = ActionRecorder.shared
        recordButton.isHidden = recorder.isRecording
        stopButton.isHidden = !recorder.isRecording
        // Saving is the step AFTER stopping: replacing the recorder's steps
        // while a session is live would throw away what it is collecting.
        saveRecordingButton.isEnabled = !recorder.isRecording && !recorder.steps.isEmpty
        playButton.isEnabled = !subjectSteps.isEmpty && ActionPlayer.frontDocument() != nil
        newButton.isEnabled = true
        duplicateButton.isEnabled = isSavedAction
        deleteButton.isEnabled = isSavedAction || isBrokenFile
        // The cheap form of `editableJSON() != nil`: every subject but the
        // empty one has JSON, and the broken one's costs a file read that
        // has no business running on every selection change.
        editJSONButton.isEnabled = hasJSONSubject
    }

    // MARK: - The subject

    private var subjectSteps: [ActionStep] {
        switch subject {
        case .recording: return ActionRecorder.shared.steps
        case .action: return loaded?.steps ?? []
        case .none, .broken: return []
        }
    }

    private var isSavedAction: Bool {
        if case .action = subject { return true }
        return false
    }

    private var isBrokenFile: Bool {
        if case .broken = subject { return true }
        return false
    }

    /// True when there is something for Edit JSON to open: a saved action, a
    /// broken file to repair, or the recording.
    private var hasJSONSubject: Bool {
        if case .none = subject { return false }
        return true
    }

    private static let recordingKey = "\u{1}recording"

    private static func key(for subject: Subject) -> String {
        switch subject {
        case .none: return ""
        case .recording: return recordingKey
        case .action(_, let summary): return "action:" + summary.name.lowercased()
        case .broken(let file, _): return "broken:" + file
        }
    }

    private static func title(for subject: Subject) -> String {
        switch subject {
        case .none: return ""
        case .recording(let live):
            let count = ActionRecorder.shared.steps.count
            return (live ? "● Recording — " : "Unsaved recording — ") + stepCount(count)
        case .action(_, let summary): return summary.name
        case .broken(let file, _): return "⚠︎ \(file)"
        }
    }

    private static func tooltip(for subject: Subject) -> String? {
        if case .broken(let file, let reason) = subject { return "\(file): \(reason)" }
        return nil
    }

    private static func stepCount(_ count: Int) -> String {
        "\(count) step\(count == 1 ? "" : "s")"
    }

    // The document a Play targets is `ActionPlayer.frontDocument()` — one
    // implementation, shared with File ▸ Automate ▸ Play and with that item's
    // own validation, so the menu and this window can never disagree about
    // whether there is anything to play on.

    // MARK: - Editing the steps of whatever is on screen

    /// Applies `change` to the subject's steps and persists it — one save
    /// per gesture. The recording lives in memory and a saved action lives
    /// in a file; this is the one place that difference is spelled out.
    ///
    /// `change` answers false for "nothing moved", which is what keeps a
    /// drag that put everything back from rewriting the file.
    @discardableResult
    private func mutateSteps(_ change: (inout [ActionStep]) -> Bool) -> Bool {
        switch subject {
        case .recording:
            var steps = ActionRecorder.shared.steps
            guard change(&steps) else { return false }
            // Posts its own change notification, which reloads us.
            ActionRecorder.shared.replaceSteps(steps)
            return true
        case .action:
            guard var action = loaded else {
                // The steps were never read — the file summarised cleanly and
                // then failed to decode — so there is nothing to change and
                // nothing this could write that would not throw the rest of
                // the file away.
                NSSound.beep()
                return false
            }
            guard change(&action.steps) else { return false }
            do {
                try ActionLibrary.save(action)
            } catch {
                present(failure: error.localizedDescription)
                return false
            }
            return true
        case .none, .broken:
            NSSound.beep()
            return false
        }
    }

    /// The step the row commands act on: the table's selection.
    private func selectedStep() -> (index: Int, step: ActionStep)? {
        let row = tableView.selectedRow
        let steps = subjectSteps
        guard row >= 0, row < steps.count else { return nil }
        return (row, steps[row])
    }

    /// `mutateSteps`, plus the row the table should end up on. A save that
    /// fails leaves no pending selection behind for the next unrelated
    /// reload to honour.
    private func applyStepChange(selecting row: Int, _ change: (inout [ActionStep]) -> Bool) {
        pendingStepSelection = row
        if !mutateSteps(change) { pendingStepSelection = nil }
    }

    // MARK: - Row commands (nil-target: the row menu and validation share them)

    @objc func toggleStepEnabled(_ sender: Any?) {
        guard let selected = selectedStep() else { return NSSound.beep() }
        applyStepChange(selecting: selected.index) { steps in
            steps[selected.index].enabled.toggle()
            return true
        }
    }

    @objc func setStepOnErrorStop(_ sender: Any?) {
        setOnError(.stop)
    }

    @objc func setStepOnErrorContinue(_ sender: Any?) {
        setOnError(.continueRun)
    }

    private func setOnError(_ policy: ActionStep.OnError) {
        guard let selected = selectedStep() else { return NSSound.beep() }
        guard selected.step.onError != policy else { return }
        applyStepChange(selecting: selected.index) { steps in
            steps[selected.index].onError = policy
            return true
        }
    }

    @objc func moveStepUp(_ sender: Any?) {
        moveSelectedStep(by: -1)
    }

    @objc func moveStepDown(_ sender: Any?) {
        moveSelectedStep(by: 1)
    }

    private func moveSelectedStep(by delta: Int) {
        guard let selected = selectedStep() else { return NSSound.beep() }
        let destination = selected.index + delta
        guard destination >= 0, destination < subjectSteps.count else { return NSSound.beep() }
        applyStepChange(selecting: destination) { steps in
            steps.swapAt(selected.index, destination)
            return true
        }
    }

    @objc func deleteStep(_ sender: Any?) {
        guard let selected = selectedStep() else { return NSSound.beep() }
        // The row that slides up into the deleted one, or the new last row
        // when the list ends there; -1 when the list is now empty, which
        // `reload` reads as "select nothing".
        applyStepChange(selecting: Swift.min(selected.index, subjectSteps.count - 2)) { steps in
            steps.remove(at: selected.index)
            return true
        }
    }

    // MARK: - Library commands

    @objc func playSelectedAction(_ sender: Any?) {
        let steps = subjectSteps
        guard !steps.isEmpty, let document = ActionPlayer.frontDocument() else {
            return NSSound.beep()
        }
        let action: Action
        switch subject {
        // `loaded`, not the summary: the steps are what runs, and
        // `subjectSteps` above has already refused an empty list.
        case .action:
            guard let saved = loaded else { return NSSound.beep() }
            action = saved
        // An unsaved recording is playable as itself: the player takes an
        // `Action`, and the name is only what the undo step is called.
        //
        // Through the recorder's OWN accessor — the one Save Recording uses —
        // so it carries `recordedCanvas` too. Assembling a bare `Action` here
        // dropped it, and with it `ActionPlayer.mismatchNote`: the same steps
        // played before saving said only "Ran Recording: 6 steps" on a
        // half-size document, and after saving said "recorded at 4000 × 3000,
        // played on 1600 × 1200 — absolute coordinates were not remapped". The
        // warning the feature leans on cannot depend on whether the user
        // happened to save first.
        case .recording: action = ActionRecorder.shared.recording(named: "Recording")
        case .none, .broken: return NSSound.beep()
        }
        let report = ActionPlayer.run(
            action, on: document, stopOnError: nil, progress: ActionRunProgress())
        ActionPlayer.notePlayed(action, report, on: document)
        statusOverride = report.text()
        updateStatus()
        if !report.ok { NSSound.beep() }
    }

    @objc func saveRecording(_ sender: Any?) {
        let recorder = ActionRecorder.shared
        guard !recorder.isRecording, !recorder.steps.isEmpty else { return NSSound.beep() }
        promptForName(
            title: "Save Recording", message: "The action is saved under this name.",
            initial: Self.defaultName(prefix: "Recording")
        ) { [weak self] name in
            guard let self = self else { return }
            let action = recorder.recording(named: name)
            guard self.save(action, outcome: "Saved “\(name)”") else { return }
            self.selectedKey = "action:" + name.lowercased()
            // The recording has become an action; leaving it in the popup as
            // well would offer the same steps twice, and the next Start
            // Recording clears it anyway. Emptying it posts the change that
            // reloads us, which is why the key above is set first.
            recorder.replaceSteps([])
        }
    }

    @objc func newAction(_ sender: Any?) {
        promptForName(
            title: "New Action",
            message: "An empty action. Add steps by recording, or with Edit JSON.",
            initial: Self.defaultName(prefix: "Action")
        ) { [weak self] name in
            guard let self = self else { return }
            guard self.save(Action(name: name, steps: []), outcome: "Created “\(name)”") else {
                return
            }
            self.selectedKey = "action:" + name.lowercased()
            self.reload()
        }
    }

    @objc func duplicateSelectedAction(_ sender: Any?) {
        guard case .action = subject, let action = loaded else { return NSSound.beep() }
        promptForName(
            title: "Duplicate Action", message: "The copy is saved under this name.",
            initial: Self.defaultName(prefix: "\(action.name) copy")
        ) { [weak self] name in
            guard let self = self else { return }
            // A copy is a NEW action: the stamps belong to the copy, not to
            // the original it was taken from.
            let copy = Action(
                name: name, steps: action.steps, recordedCanvas: action.recordedCanvas,
                raw: action.raw)
            guard self.save(copy, outcome: "Duplicated as “\(name)”") else { return }
            self.selectedKey = "action:" + name.lowercased()
            self.reload()
        }
    }

    @objc func deleteSelectedAction(_ sender: Any?) {
        // Both the name shown and the deletion itself are captured HERE,
        // before the sheet goes up, and the commit below uses the captured
        // pair — the sheet rule in app/CLAUDE.md: a document-modal sheet does
        // not stop the main run loop, so a recording step, an
        // `ActionLibrary` write from the agent or a reload could change the
        // subject underneath it, and a commit read from the CURRENT subject
        // would then delete something the user never saw named.
        let what: String
        let deletion: () throws -> Void
        switch subject {
        case .action(_, let summary):
            what = summary.name
            deletion = { try ActionLibrary.delete(summary.name) }
        case .broken(let file, _):
            // A file that will not decode has no readable name to delete by,
            // so it goes by the file name the library listed it under.
            what = file
            deletion = {
                let url = ActionLibrary.directory.appendingPathComponent(file)
                try FileManager.default.removeItem(at: url)
                ActionLibrary.postDidChange(changed: url)
            }
        case .none, .recording:
            return NSSound.beep()
        }
        // Deleting an action deletes a FILE. Nothing in the app can bring it
        // back — there is no undo stack over Application Support — so it
        // asks first, unlike the panels' own delete buttons, which are all
        // one ⌘Z away from being undone.
        let alert = NSAlert()
        alert.messageText = "Delete “\(what)”?"
        alert.informativeText = "The action's file is removed. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let confirm: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            do {
                try deletion()
            } catch {
                self.present(failure: error.localizedDescription)
                return
            }
            self.selectedKey = ""
            self.statusOverride = "Deleted “\(what)”"
            self.reload()
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: confirm)
        } else {
            confirm(alert.runModal())
        }
    }

    // MARK: - Edit JSON

    /// What Edit JSON opens on: a title, the text to show, and what to do
    /// with a decoded action. nil when the subject has no JSON at all.
    private func editableJSON() -> (title: String, hint: String, json: String, url: URL?)? {
        switch subject {
        case .none:
            return nil
        case .recording:
            let action = Action(name: "Recording", steps: ActionRecorder.shared.steps)
            return (
                "Edit Recording",
                "Applying replaces the recording's steps. The name here is not saved — "
                    + "use Save Recording for that.",
                Self.pretty(action.encoded()), nil
            )
        case .action(let url, let summary):
            // The FILE's own bytes when they can be read, so a hand-written
            // action comes back exactly as it is — its own key order and
            // whatever it carries that this build does not read. Applying
            // rewrites it in the canonical form (`Action.encoded`), which is
            // what drops such a key, and what re-stamps `modified` so
            // File ▸ Automate ▸ Play Last Action means the one just edited.
            // Read from the row's OWN url, which is also what the editor
            // writes back to — and which is what lets an action whose steps
            // will not decode be repaired here at all.
            let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? loaded.map { Self.pretty($0.encoded()) } ?? ""
            return (
                "Edit “\(summary.name)”",
                loadFailure ?? "Written to \(url.lastPathComponent) when it validates.",
                text, url
            )
        case .broken(let file, let reason):
            let url = ActionLibrary.directory.appendingPathComponent(file)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return ("Repair \(file)", reason, text, url)
        }
    }

    @objc func editActionJSON(_ sender: Any?) {
        // Captured before the sheet opens and used by its commit — the same
        // rule `deleteSelectedAction` states: the subject can change while a
        // document-modal sheet is up, and the file this editor was opened on
        // is the file it must write.
        guard let editable = editableJSON() else { return NSSound.beep() }
        let isRecording: Bool
        if case .recording = subject { isRecording = true } else { isRecording = false }
        let sheet = ActionJSONSheetController(
            title: editable.title, hint: editable.hint, json: editable.json
        ) { [weak self] action, _ in
            guard let self = self else { return "the Actions window went away" }
            if isRecording {
                ActionRecorder.shared.replaceSteps(action.steps)
                return nil
            }
            guard let url = editable.url else { return "this action has no file to write to" }
            // A rename through the editor may not take a name another FILE
            // already answers to: the display name is what every lookup
            // resolves on (case-insensitively), so two files claiming one
            // name make `run_action`, Play and Delete pick whichever the
            // directory listed first. Refused with the reason, in the same
            // channel a malformed edit is refused in. Compared by PATH, not
            // by URL: the two are built by different callers and only the
            // path is guaranteed to spell the same file the same way.
            if let other = ActionLibrary.fileURL(forActionNamed: action.name),
                other.path != url.path
            {
                return "another action is already named “\(action.name)” "
                    + "(\(other.lastPathComponent)) — two files answering to one name "
                    + "make every lookup ambiguous"
            }
            // Written back to the SAME file, re-encoded rather than saved
            // through `ActionLibrary.save`: the name inside the file is
            // authoritative and the file name is only a slug, so a rename
            // through the editor must keep the one file it was opened on —
            // `save` would look the new name up, find nothing, and mint a
            // second file beside the first.
            var updated = action
            updated.created = action.created ?? Date()
            updated.modified = Date()
            do {
                try updated.encoded().write(to: url, options: [.atomic])
            } catch {
                return "could not write \(url.lastPathComponent): \(error.localizedDescription)"
            }
            self.selectedKey = "action:" + action.name.lowercased()
            self.statusOverride = "Saved \(url.lastPathComponent)"
            ActionLibrary.postDidChange(changed: url)
            return nil
        }
        presentAsSheet(sheet)
    }

    /// The file's own bytes as text. `Action.encoded()` has already laid
    /// them out — pretty-printed with sorted keys, or compact once the
    /// action is past the size anyone edits by hand — so this only decodes.
    private static func pretty(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    // MARK: - Small dialogs

    private func save(_ action: Action, outcome: String) -> Bool {
        do {
            try ActionLibrary.save(action)
        } catch {
            present(failure: error.localizedDescription)
            return false
        }
        statusOverride = outcome
        return true
    }

    /// A name that does not collide with one already in the library, so the
    /// prompt opens on something the user can accept unchanged.
    private static func defaultName(prefix: String) -> String {
        let taken = Set(ActionLibrary.names().map { $0.lowercased() })
        guard taken.contains(prefix.lowercased()) else { return prefix }
        for suffix in 2..<1000 where !taken.contains("\(prefix) \(suffix)".lowercased()) {
            return "\(prefix) \(suffix)"
        }
        return prefix
    }

    /// The name prompt behind New Action, Save Recording and Duplicate
    /// Action — and so the ONE place a name that already belongs to another
    /// action is caught, for all three at once.
    ///
    /// **A save under a taken name destroys that action.** `ActionLibrary`
    /// resolves a name onto the existing FILE case-insensitively, so typing
    /// "web export" over a 20-step "Web Export" rewrote it, and New Action
    /// rewrote it with an EMPTY one — with nothing to bring it back, the same
    /// fact `deleteSelectedAction` asks about before it deletes a file. The
    /// MCP twins refuse it outright (`save_action` wants `overwrite: true`,
    /// `stop_recording` refuses a taken name and keeps recording), so the
    /// window asks rather than clobbering, in that delete confirmation's
    /// shape.
    private func promptForName(
        title: String, message: String, initial: String, then: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                NSSound.beep()
                return
            }
            guard let existing = ActionLibrary.summary(named: name) else {
                then(name)
                return
            }
            self.confirmReplacing(existing) { then(name) }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Replace/Cancel for a name another action already holds. Cancel does
    /// nothing at all — the prompt is one keystroke away and re-opening it
    /// with the typed name would put a third sheet in the chain.
    private func confirmReplacing(_ existing: ActionSummary, then: @escaping () -> Void) {
        let count = existing.stepCount
        let alert = NSAlert()
        alert.messageText = "Replace “\(existing.name)”?"
        alert.informativeText =
            "An action with that name already exists. Its "
            + "\(count) step\(count == 1 ? "" : "s") "
            + "\(count == 1 ? "is" : "are") overwritten. This cannot be undone."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        let confirm: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            then()
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: confirm)
        } else {
            confirm(alert.runModal())
        }
    }

    /// A write or a delete that the filesystem refused, with its own reason.
    private func present(failure message: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "The Actions library could not be changed."
        alert.informativeText = message
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Validation

    /// The row menu's items carry nil targets, so AppKit asks whoever the
    /// responder chain finds — this controller — whether each can run. The
    /// footer's buttons cannot be validated this way (AppKit never validates
    /// a nil-target button), which is why `updateButtonStates` restates the
    /// same rules.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleStepEnabled(_:)), #selector(setStepOnErrorStop(_:)),
            #selector(setStepOnErrorContinue(_:)), #selector(deleteStep(_:)):
            return selectedStep() != nil
        case #selector(moveStepUp(_:)):
            guard let selected = selectedStep() else { return false }
            return selected.index > 0
        case #selector(moveStepDown(_:)):
            guard let selected = selectedStep() else { return false }
            return selected.index < subjectSteps.count - 1
        case #selector(playSelectedAction(_:)):
            return !subjectSteps.isEmpty && ActionPlayer.frontDocument() != nil
        case #selector(saveRecording(_:)):
            let recorder = ActionRecorder.shared
            return !recorder.isRecording && !recorder.steps.isEmpty
        case #selector(duplicateSelectedAction(_:)):
            return isSavedAction
        case #selector(deleteSelectedAction(_:)):
            return isSavedAction || isBrokenFile
        case #selector(editActionJSON(_:)):
            return hasJSONSubject
        default:
            return true
        }
    }
}

// MARK: - Table data source / delegate

extension ActionsViewController: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { subjectSteps.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let steps = subjectSteps
        guard row < steps.count else { return nil }
        let cell = ActionStepCellView(frame: .zero)
        cell.configure(number: row + 1, step: steps[row])
        cell.onToggleEnabled = { [weak self] in
            guard let self = self else { return }
            // The checkbox acts on the row it is IN, not on the selection —
            // clicking a checkbox does not move the selection — so it
            // selects that row first and then shares `toggleStepEnabled`.
            self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            self.toggleStepEnabled(nil)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LayerRowView(frame: .zero)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        updateButtonStates()
    }

    // MARK: Drag reorder

    func tableView(
        _ tableView: NSTableView, pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        // Only a list of steps can be reordered: a broken file has none, and
        // the recording's own list is editable like any other.
        guard row >= 0, row < subjectSteps.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.stepRowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingPasteboard.availableType(from: [Self.stepRowType]) != nil,
              !draggedRows(info).isEmpty
        else { return [] }
        // A step list is flat — there is nothing to drop ONTO — so every
        // drop is an insertion between rows.
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let sources = draggedRows(info)
        guard !sources.isEmpty else { return false }
        // ONE save for the whole gesture, and an early return when the drag
        // put everything back where it started — the simple half of the
        // Layers panel's pattern. A drag that changed nothing leaves no
        // pending selection behind either.
        pendingStepSelection = Self.landingRow(moving: sources, to: row)
        let moved = mutateSteps { steps in
            guard let reordered = Self.reorder(steps, moving: sources, to: row) else {
                return false
            }
            steps = reordered
            return true
        }
        if !moved { pendingStepSelection = nil }
        return moved
    }

    private func draggedRows(_ info: NSDraggingInfo) -> [Int] {
        var rows: [Int] = []
        info.enumerateDraggingItems(
            options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, _, _ in
            guard let pasteboardItem = item.item as? NSPasteboardItem,
                  let text = pasteboardItem.string(forType: Self.stepRowType),
                  let row = Int(text)
            else { return }
            rows.append(row)
        }
        return rows.sorted()
    }

    /// `steps` with the rows at `sources` moved so they sit at the insertion
    /// point `row` (a between-rows index, 0…count), or nil when that is
    /// where they already are.
    ///
    /// Pure, and separate from the drop handler, so the index arithmetic can
    /// be read on its own: the insertion point is expressed in the array
    /// with the moved rows already pulled out, which is what makes dropping
    /// a row onto its own edges a no-op rather than an off-by-one.
    static func reorder(
        _ steps: [ActionStep], moving sources: [Int], to row: Int
    ) -> [ActionStep]? {
        let sorted = sources.sorted()
        guard row >= 0, row <= steps.count,
              sorted.allSatisfy({ steps.indices.contains($0) })
        else { return nil }
        let insert = row - sorted.filter { $0 < row }.count
        // The rows already occupy exactly the destination run: dropping a
        // row immediately above or below itself changes nothing, and an
        // action file must not be rewritten for it.
        guard sorted != Array(insert..<(insert + sorted.count)) else { return nil }
        let moved = Set(sorted)
        var rest = steps.enumerated().filter { !moved.contains($0.offset) }.map { $0.element }
        rest.insert(contentsOf: sorted.map { steps[$0] }, at: insert)
        return rest
    }

    /// Where the first moved row lands, so the selection follows the drag.
    private static func landingRow(moving sources: [Int], to row: Int) -> Int {
        let sorted = sources.sorted()
        return Swift.max(row - sorted.filter { $0 < row }.count, 0)
    }

    // MARK: Row menu

    /// Built for the row under the cursor and SELECTING it first, so the
    /// menu, the footer and validation always act on the same step.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        let steps = subjectSteps
        guard row >= 0, row < steps.count else { return }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let step = steps[row]
        menu.addItem(
            Self.menuItem(
                step.enabled ? "Disable Step" : "Enable Step", #selector(toggleStepEnabled(_:))))

        let onError = NSMenu(title: "On Error")
        let stop = Self.menuItem("Stop", #selector(setStepOnErrorStop(_:)))
        stop.state = step.onError == .stop ? .on : .off
        let carryOn = Self.menuItem("Continue", #selector(setStepOnErrorContinue(_:)))
        carryOn.state = step.onError == .continueRun ? .on : .off
        onError.addItem(stop)
        onError.addItem(carryOn)
        let onErrorItem = NSMenuItem(title: "On Error", action: nil, keyEquivalent: "")
        onErrorItem.submenu = onError
        menu.addItem(onErrorItem)

        menu.addItem(.separator())
        menu.addItem(Self.menuItem("Move Up", #selector(moveStepUp(_:))))
        menu.addItem(Self.menuItem("Move Down", #selector(moveStepDown(_:))))
        menu.addItem(.separator())
        menu.addItem(Self.menuItem("Delete Step", #selector(deleteStep(_:))))
    }

    /// Nil target on purpose: the menu and the footer share one set of
    /// handlers and one set of validation rules.
    private static func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }
}
