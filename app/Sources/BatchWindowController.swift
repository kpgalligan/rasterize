import AppKit

/// File ▸ Automate ▸ Batch… — run one action over every image in a folder.
///
/// One app-modal window with two panes swapped in place: **Setup**, then
/// **Run/Report**. Modal because it has to work with no document open,
/// because editing the front document while a run is in flight would be
/// wrong, and because `NSApp.runModal`'s run loop is what drives the file
/// machine and the Stop button. `ModalCardWindowController` carries the
/// full reasoning for the idiom; this is its second user, which is why it
/// is a shared file rather than the RAW dialog's private detail.
///
/// Batch has **no MCP twin, deliberately**, and that does not violate the
/// agent-parity rule: it performs no edit of its own — it is
/// `open_document` + `run_action` + `save_copy` in a loop, and an agent
/// already has all three. The rules that are Batch's own — the folder walk,
/// the naming template, containment, the two halves of "stop on error" —
/// live in `BatchRun` as pure functions and a driver.
final class BatchWindowController: NSObject, NSTextFieldDelegate {
    /// Presents the Batch window, app-modally.
    ///
    /// An empty library is answered with a sentence rather than an empty
    /// pop-up: Batch's whole input is an action, and a window whose first
    /// control has nothing in it cannot say why.
    static func present() {
        // SUMMARIES: the pop-up needs names, and the chosen action's steps
        // are read when the run starts (`Action.decodeSummary` says why a
        // window must not decode a library to open).
        let actions = ActionLibrary.entries().compactMap { entry -> LibraryRow? in
            guard case .ok(let summary) = entry.result else { return nil }
            return LibraryRow(url: entry.url, summary: summary)
        }
        .sorted { $0.summary.name.localizedStandardCompare($1.summary.name) == .orderedAscending }
        guard !actions.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "There are no actions to run"
            alert.informativeText =
                "Batch runs a saved action over a folder of images. Record one first: "
                + "File ▸ Automate ▸ Start Recording, make the edits once, then Stop "
                + "Recording and name it."
            alert.runModal()
            return
        }
        BatchWindowController(actions: actions).runModalSession()
    }

    // MARK: - State

    /// One row of the pop-up: an action's summary and the file it came from,
    /// which is where its steps are read from when the run starts.
    struct LibraryRow {
        let url: URL
        var summary: ActionSummary
    }

    /// The library's valid actions, as they stood when the window opened.
    /// A `var` because editing an action's RAW settings here writes it back,
    /// and the entry has to keep up or the "did anything change?" test would
    /// compare against a stale value and rewrite the file every time.
    private var actions: [LibraryRow]
    private var actionIndex = 0
    /// The develop settings the run opens camera RAWs with: the selected
    /// action's own `raw` object, edited here and written back when the run
    /// starts. This is the ONLY way a folder of 200 RAWs gets anything but
    /// as-shot defaults, because no dialog can be shown per file.
    private var raw = RawDevelopSettings()
    /// Slider positions for the RAW knobs, whether or not each one is set:
    /// a knob that is switched on has to have somewhere to start from.
    private var rawSliderValues: [Double] = []
    private var inputFolder: URL?
    private var outputFolder: URL?
    private var template = "{name}"
    private var overwrite = false
    private var stopOnError = true
    /// Non-nil when the action's RAW settings could not be written back.
    /// Reported at the top of the run's report rather than as an alert,
    /// which would interrupt a run the user has already started.
    private var rawSaveNote: String?

    private var modal: ModalCardWindowController?
    private var setupCard: NSView?
    private var driver: BatchRun?

    // MARK: - Views

    private let exportOptions = ExportAccessoryController()
    private let rawSummary = NSTextField(labelWithString: "As shot")
    private let rawDisclosure = NSButton()
    private let rawStack = NSStackView()
    private let rawScroll = NSScrollView()
    private var rawScrollHeight: NSLayoutConstraint?
    private var rawRows: [CardControlRow] = []
    private var rawChecks: [NSButton] = []
    private var whiteBalanceRow: CardControlRow?
    private var lensRow: CardControlRow?
    private var highlightRow: CardControlRow?
    private let inputLabel = BatchWindowController.pathLabel()
    private let outputLabel = BatchWindowController.pathLabel()
    private let templateField = NSTextField()
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let reportView = NSTextView()
    private let reportScroll = NSScrollView()
    private var stopButton: NSButton?
    private var doneButton: NSButton?
    private var copyButton: NSButton?

    /// Wider than the house 420 pt card, because two of its rows are wider
    /// than one: a folder row is the 106 pt label column plus a Choose…
    /// button plus a path readout, and a RAW knob row is the
    /// 106/12/180/12/52 card grid plus its checkbox — 388 pt, inside a
    /// scroll view that may put a 15 pt legacy scroller over its own right
    /// edge. 480 leaves both room without the card's trailing inset having
    /// to give way.
    private static let cardWidth: CGFloat = 480

    /// The content width inside those insets — every row that has to be
    /// pinned rather than sized by its own content uses it.
    private static let contentWidth = cardWidth - sheetInset * 2

    /// Room for the title bar plus a margin above and below, since a card
    /// is measured without its window (`fitToScreen`).
    private static let windowChrome: CGFloat = 60

    /// How tall the RAW knob list may get before it scrolls. Thirteen rows
    /// stand about 500 pt, which would put the buttons below the fold of a
    /// laptop screen once the folder rows and the export options are above
    /// it; 380 shows nine at a time.
    private static let maximumRawHeight: CGFloat = 380

    /// How short that list may get on a small screen. About four rows,
    /// which is the least that still reads as a list rather than a slot.
    private static let minimumRawHeight: CGFloat = 140

    /// `present()` is the only caller, and it refuses an empty library
    /// before reaching here — which is what makes the first entry safe to
    /// read.
    private init(actions: [LibraryRow]) {
        self.actions = actions
        super.init()
        loadRaw(from: actions[0].summary)
    }

    // MARK: - The modal session

    private func runModalSession() {
        let card = makeSetupCard()
        setupCard = card
        let modal = ModalCardWindowController(title: "Batch", card: card)
        self.modal = modal
        fitToScreen()
        _ = modal.runModal()
        // The run is always over by the time the session ends: Stop is the
        // only way out while one is in flight, and the report pane's Done
        // button does not appear until the driver has finished.
        self.modal = nil
        setupCard = nil
    }

    /// Swaps the window's card and resizes around it, keeping the title bar
    /// where it is — a modal window that jumped up the screen between panes
    /// would read as a different window.
    private func install(_ card: NSView) {
        guard let window = modal?.window else { return }
        window.contentView = card
        resize(to: card)
    }

    private func resize(to card: NSView) {
        guard let window = modal?.window else { return }
        card.layoutSubtreeIfNeeded()
        let framed = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: card.fittingSize))
        var frame = window.frame
        frame.origin.y += frame.height - framed.height
        frame.size = framed.size
        window.setFrame(frame, display: true)
    }

    /// Gives the RAW knob list whatever height the screen cannot spare.
    ///
    /// That list is the part that yields because it is the only part that
    /// can: the folder rows, the export options and the buttons under them
    /// must all stay reachable in a window that cannot scroll, and the list
    /// is already inside a scroll view. The Develop dialog's preview yields
    /// the same way for the same reason.
    private func fitToScreen() {
        guard let card = setupCard else { return }
        if let height = rawScrollHeight, let available = NSScreen.main?.visibleFrame.height {
            card.layoutSubtreeIfNeeded()
            let overflow = card.fittingSize.height + Self.windowChrome - available
            if overflow > 0 {
                height.constant = max(Self.minimumRawHeight, height.constant - overflow)
            }
        }
        resize(to: card)
    }

    // MARK: - Setup pane

    private func makeSetupCard() -> NSView {
        var rows: [NSView] = []

        rows.append(
            cardPopupRow(
                label: "Action:", titles: actions.map { $0.summary.name }, selected: 0
            ) { [weak self] index in
                self?.actionChanged(index)
            })
        rows.append(makeRawHeaderRow())
        rows.append(makeRawList())
        rows.append(
            folderRow(
                label: "Input folder:", action: #selector(chooseInput(_:)), path: inputLabel))
        rows.append(
            folderRow(
                label: "Output folder:", action: #selector(chooseOutput(_:)), path: outputLabel))

        // Reused verbatim, capability table and all: it is a plain
        // NSViewController with no panel dependency, and restating what each
        // format can carry is exactly the duplication that goes stale. Its
        // grid centres itself inside its container, so the container is
        // pinned to the card's content width to centre it in the card.
        exportOptions.view.translatesAutoresizingMaskIntoConstraints = false
        exportOptions.view.widthAnchor.constraint(
            equalToConstant: Self.contentWidth).isActive = true
        rows.append(exportOptions.view)
        rows.append(
            note(
                "Every file is written flattened, in one of those formats. The layered .rz "
                    + "format is not offered here: a batch produces copies, and a copy of a "
                    + "document is the picture it makes."))

        DSField.style(templateField)
        templateField.stringValue = template
        templateField.delegate = self
        templateField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let nameRow = NSStackView(views: [labelColumn("Name as:"), templateField])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 12
        rows.append(nameRow)
        rows.append(
            note(
                "Tokens: {name} (the input file's own name) and {n} (1, 2, 3…, zero-padded). "
                    + "The extension always comes from the format above."))

        rows.append(
            cardCheckboxRow(
                label: "Existing files:", title: "Overwrite existing files", on: overwrite
            ) { [weak self] on in
                self?.overwrite = on
            })
        rows.append(
            cardCheckboxRow(
                label: "On error:", title: "Stop the whole run", on: stopOnError
            ) { [weak self] on in
                self?.stopOnError = on
            })
        rows.append(
            note(
                "On: a failed step halts the run, and the file it was working on is not "
                    + "written. Off: that file is written as the action left it, and every "
                    + "failed step is listed against it in the report."))

        problemLabel.font = DS.sans(12)
        // The refusal colour the assistant panel already uses for an error
        // line, so a refusal reads the same wherever it comes from.
        problemLabel.textColor = .systemRed
        problemLabel.preferredMaxLayoutWidth = Self.contentWidth
        problemLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        problemLabel.isHidden = true
        rows.append(problemLabel)

        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10

        let cancel = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let start = StickerButton(
            title: "Run", style: .primary, target: self, action: #selector(runClicked(_:)))
        return makeSheetView(
            title: "Batch",
            hint: "Runs the action on every image in the input folder — its top level only, "
                + "not sub-folders — and writes each result into the output folder.",
            content: content,
            buttonRow: makeButtonRow(cancel: cancel, apply: start),
            width: Self.cardWidth)
    }

    /// A 106 pt right-aligned label: the card grid's first column.
    private func labelColumn(_ text: String) -> NSTextField {
        let label = fieldLabel(text)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 106).isActive = true
        return label
    }

    /// A wrapped muted footnote under a row, for the rules that need a
    /// sentence rather than a label.
    private func note(_ text: String, width: CGFloat = contentWidth) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = DS.sans(11)
        label.textColor = DS.textMuted
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func folderRow(label: String, action: Selector, path: NSTextField) -> NSStackView {
        let button = StickerButton(
            title: "Choose…", style: .secondary, target: self, action: action)
        let row = NSStackView(views: [labelColumn(label), button, path])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    /// A path readout: truncated at the HEAD, because the tail of a path is
    /// the part that identifies the folder, with the whole path as its
    /// tooltip.
    private static func pathLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "None chosen")
        label.font = DS.mono(11)
        label.textColor = DS.textMuted
        label.lineBreakMode = .byTruncatingHead
        label.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return label
    }

    // MARK: - The RAW disclosure

    private func makeRawHeaderRow() -> NSStackView {
        rawDisclosure.setButtonType(.pushOnPushOff)
        rawDisclosure.bezelStyle = .disclosure
        rawDisclosure.title = ""
        rawDisclosure.state = .off
        rawDisclosure.target = self
        rawDisclosure.action = #selector(rawDisclosureClicked(_:))
        rawSummary.font = DS.sans(12)
        rawSummary.textColor = DS.textMuted
        rawSummary.lineBreakMode = .byTruncatingTail
        rawSummary.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let row = NSStackView(views: [labelColumn("RAW develop:"), rawDisclosure, rawSummary])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    /// The knob list, collapsed by default and living in a scroll view so a
    /// screen that cannot hold all thirteen rows scrolls them instead of
    /// pushing the buttons off the bottom of a window that cannot scroll.
    private func makeRawList() -> NSView {
        var rows: [NSView] = [
            note(
                "These settings develop every camera RAW in the folder — no dialog can be "
                    + "shown per file. An unchecked knob keeps each file's own value. They "
                    + "belong to the action and are saved with it when the run starts.",
                width: Self.rawListWidth)
        ]
        var placedWhiteBalance = false
        for (index, knob) in Self.rawKnobs.enumerated() {
            let row = cardSliderRow(
                label: knob.label, min: knob.range.lowerBound, max: knob.range.upperBound,
                value: rawSliderValues[index],
                format: { [weak self] value in self?.rawReadout(index, value) ?? "" }
            ) { [weak self] value in
                self?.rawKnobChanged(index, value)
            }
            rawRows.append(row)
            let check = NSButton(
                checkboxWithTitle: "", target: self, action: #selector(rawCheckClicked(_:)))
            check.tag = index
            check.toolTip =
                "Use this value for every RAW in the folder. Unchecked keeps each file's own."
            check.state = knob.read(raw) != nil ? .on : .off
            rawChecks.append(check)
            if knob.whiteBalance {
                // Temperature and tint are ONE control: passing either to
                // the decoder leaves the as-shot balance behind, so the
                // pop-up above them governs both and they carry no checkbox.
                check.isHidden = true
                if !placedWhiteBalance {
                    placedWhiteBalance = true
                    let popup = cardPopupRow(
                        label: "White balance:", titles: ["As shot", "Custom"],
                        selected: isCustomWhiteBalance ? 1 : 0
                    ) { [weak self] choice in
                        self?.whiteBalanceChanged(choice == 1)
                    }
                    whiteBalanceRow = popup
                    rows.append(popup)
                }
            }
            let pair = NSStackView(views: [row, check])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = 8
            rows.append(pair)
        }

        let lens = cardPopupRow(
            label: "Lens correction:", titles: Self.flagTitles,
            selected: Self.flagIndex(raw.lensCorrection)
        ) { [weak self] index in
            self?.raw.lensCorrection = Self.flagValue(index)
            self?.rawChanged()
        }
        lensRow = lens
        rows.append(lens)

        // macOS 26+ only; gated because the deployment floor is 15. Hidden
        // rather than disabled below 26, exactly as the Develop dialog does
        // it — and an action loaded on an older system can never carry the
        // setting either, since the shared parser refuses the key by name
        // there.
        if #available(macOS 26.0, *) {
            let highlights = cardPopupRow(
                label: "Highlights:", titles: Self.flagTitles,
                selected: Self.flagIndex(raw.highlightRecovery)
            ) { [weak self] index in
                self?.raw.highlightRecovery = Self.flagValue(index)
                self?.rawChanged()
            }
            highlightRow = highlights
            rows.append(highlights)
        }

        // Orientation first, then the rows: an NSStackView is horizontal
        // until it is told otherwise, and rows added to a horizontal stack
        // would be laid out side by side.
        rawStack.orientation = .vertical
        rawStack.alignment = .leading
        rawStack.spacing = 10
        rawStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        rawStack.translatesAutoresizingMaskIntoConstraints = false
        rows.forEach(rawStack.addArrangedSubview)
        rawScroll.documentView = rawStack
        rawScroll.hasVerticalScroller = true
        rawScroll.autohidesScrollers = true
        rawScroll.drawsBackground = false
        rawScroll.borderType = .lineBorder
        rawScroll.isHidden = true
        // Pinned on three sides to the clip view: the stack's width follows
        // the scroll view and its HEIGHT is what scrolls.
        let clip = rawScroll.contentView
        // Its natural height, capped both ways: the ceiling is what keeps
        // the buttons on screen, and the floor is what keeps the list
        // visible at all if `fittingSize` cannot answer for a stack that is
        // not in a window yet.
        let natural = min(
            max(rawStack.fittingSize.height, Self.minimumRawHeight), Self.maximumRawHeight)
        let height = rawScroll.heightAnchor.constraint(equalToConstant: natural)
        NSLayoutConstraint.activate([
            rawStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            rawStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            rawStack.topAnchor.constraint(equalTo: clip.topAnchor),
            rawScroll.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            height,
        ])
        rawScrollHeight = height
        applyRawEnablement()
        rawChanged()
        return rawScroll
    }

    /// The width a row inside the knob list gets: the card's content width
    /// less the list's own 8 pt insets and the scroller AppKit may put over
    /// its right edge.
    private static let rawListWidth = contentWidth - 40

    /// One RAW knob the action's `raw` object can carry, in the Develop
    /// dialog's own order and with its labels, ranges and formats — so the
    /// same setting reads the same in both places.
    ///
    /// The `seed` is where a slider starts when the action does not set that
    /// knob. It cannot be "the file's own value" the way the Develop
    /// dialog's default is, because a batch has no one file to ask; each is
    /// the framework's own typical default where `CIRAWFilter.h` and the
    /// phase's measurements give one (1 for the tone curve, 0.9 for the
    /// shadow boost, the 0.5 that sharpness and both noise knobs report on a
    /// freshly built filter), 5500 K for daylight, and no-change for
    /// exposure and tint.
    private struct RawKnob {
        let label: String
        let range: ClosedRange<Double>
        let seed: Double
        let format: (Double) -> String
        let read: (RawDevelopSettings) -> Double?
        let write: (inout RawDevelopSettings, Double?) -> Void
        /// True for temperature and tint, which the white-balance pop-up
        /// governs together instead of a checkbox each.
        var whiteBalance = false
    }

    private static let rawKnobs: [RawKnob] = [
        RawKnob(
            label: "Exposure:", range: RawDevelopRange.exposure, seed: 0,
            format: { String(format: "%+.2f EV", $0) }, read: { $0.exposure },
            write: { $0.exposure = $1 }),
        RawKnob(
            label: "Temperature:", range: RawDevelopRange.temperature, seed: 5500,
            format: { String(format: "%.0f K", $0) }, read: { $0.temperature },
            write: { $0.temperature = $1 }, whiteBalance: true),
        RawKnob(
            label: "Tint:", range: RawDevelopRange.tint, seed: 0,
            format: { String(format: "%.0f", $0) }, read: { $0.tint },
            write: { $0.tint = $1 }, whiteBalance: true),
        RawKnob(
            label: "Tone curve:", range: RawDevelopRange.toneCurve, seed: 1,
            format: { String(format: "%.2f", $0) }, read: { $0.toneCurve },
            write: { $0.toneCurve = $1 }),
        RawKnob(
            label: "Shadows:", range: RawDevelopRange.shadows, seed: 0.9,
            format: { String(format: "%.2f", $0) }, read: { $0.shadows },
            write: { $0.shadows = $1 }),
        RawKnob(
            label: "Local contrast:", range: RawDevelopRange.contrast, seed: 0.5,
            format: { String(format: "%.2f", $0) }, read: { $0.contrast },
            write: { $0.contrast = $1 }),
        RawKnob(
            label: "Sharpness:", range: RawDevelopRange.sharpness, seed: 0.5,
            format: { String(format: "%.2f", $0) }, read: { $0.sharpness },
            write: { $0.sharpness = $1 }),
        RawKnob(
            label: "Detail:", range: RawDevelopRange.detail, seed: 0.5,
            format: { String(format: "%.2f", $0) }, read: { $0.detail },
            write: { $0.detail = $1 }),
        RawKnob(
            label: "Luminance noise:", range: RawDevelopRange.luminanceNoise, seed: 0.5,
            format: { String(format: "%.2f", $0) }, read: { $0.luminanceNoise },
            write: { $0.luminanceNoise = $1 }),
        RawKnob(
            label: "Colour noise:", range: RawDevelopRange.colorNoise, seed: 0.5,
            format: { String(format: "%.2f", $0) }, read: { $0.colorNoise },
            write: { $0.colorNoise = $1 }),
    ]

    /// A tri-state flag. "As shot" is the ABSENT value, and it is a real
    /// third choice rather than a synonym for Off: Off turns the correction
    /// off for every file, As shot leaves each file's own decoder default
    /// alone.
    private static let flagTitles = ["As shot", "On", "Off"]

    private static func flagIndex(_ value: Bool?) -> Int {
        guard let value = value else { return 0 }
        return value ? 1 : 2
    }

    private static func flagValue(_ index: Int) -> Bool? {
        switch index {
        case 1: return true
        case 2: return false
        default: return nil
        }
    }

    private var isCustomWhiteBalance: Bool { raw.temperature != nil || raw.tint != nil }

    /// A slider's readout: the value when the knob is set, "as shot" when it
    /// is not — so an unchecked row says what will happen instead of showing
    /// a number nothing will use.
    private func rawReadout(_ index: Int, _ value: Double) -> String {
        guard Self.rawKnobs.indices.contains(index) else { return "" }
        let knob = Self.rawKnobs[index]
        guard knob.read(raw) != nil else { return "as shot" }
        return knob.format(value)
    }

    private func loadRaw(from action: ActionSummary) {
        raw = action.raw ?? RawDevelopSettings()
        rawSliderValues = Self.rawKnobs.map { $0.read(raw) ?? $0.seed }
    }

    private func rawKnobChanged(_ index: Int, _ value: Double) {
        guard Self.rawKnobs.indices.contains(index) else { return }
        let knob = Self.rawKnobs[index]
        // Clamped before it is stored. A slider cannot leave its track, but
        // these ranges are the framework's own documented ones and the value
        // travels to the same parser the MCP path refuses against.
        let clamped = knob.range.clamping(value, fallback: knob.seed)
        rawSliderValues[index] = clamped
        if knob.read(raw) != nil { knob.write(&raw, clamped) }
        rawChanged()
    }

    @objc private func rawCheckClicked(_ sender: NSButton) {
        let index = sender.tag
        guard Self.rawKnobs.indices.contains(index), rawRows.indices.contains(index) else {
            return
        }
        let knob = Self.rawKnobs[index]
        knob.write(&raw, sender.state == .on ? rawSliderValues[index] : nil)
        // Re-set silently so the readout flips between the number and
        // "as shot" without calling back into `rawKnobChanged`.
        rawRows[index].setValue(rawSliderValues[index])
        applyRawEnablement()
        rawChanged()
    }

    private func whiteBalanceChanged(_ custom: Bool) {
        for (index, knob) in Self.rawKnobs.enumerated()
        where knob.whiteBalance && rawRows.indices.contains(index) {
            knob.write(&raw, custom ? rawSliderValues[index] : nil)
            rawRows[index].setValue(rawSliderValues[index])
        }
        applyRawEnablement()
        rawChanged()
    }

    /// A knob that is not set reads as not set: its row is dimmed, and its
    /// slider cannot be dragged until the checkbox says the value will be
    /// used.
    private func applyRawEnablement() {
        for (index, knob) in Self.rawKnobs.enumerated() where rawRows.indices.contains(index) {
            rawRows[index].isEnabled = knob.read(raw) != nil
        }
    }

    private func rawChanged() {
        let summary = rawSummaryText
        rawSummary.stringValue = summary
        rawSummary.toolTip = summary
    }

    /// "As shot", or the settings that are actually set — the disclosure
    /// header has to say what a collapsed row is hiding.
    private var rawSummaryText: String {
        var parts: [String] = []
        for knob in Self.rawKnobs {
            guard let value = knob.read(raw) else { continue }
            let name = knob.label.replacingOccurrences(of: ":", with: "").lowercased()
            parts.append("\(name) \(knob.format(value))")
        }
        if let lens = raw.lensCorrection { parts.append("lens correction \(lens ? "on" : "off")") }
        if let recovery = raw.highlightRecovery {
            parts.append("highlights \(recovery ? "on" : "off")")
        }
        guard !parts.isEmpty else { return "As shot" }
        guard parts.count > 3 else { return parts.joined(separator: ", ") }
        return parts.prefix(3).joined(separator: ", ") + ", +\(parts.count - 3) more"
    }

    @objc private func rawDisclosureClicked(_ sender: NSButton) {
        rawScroll.isHidden = sender.state != .on
        fitToScreen()
    }

    // MARK: - Setup actions

    private func actionChanged(_ selection: Int) {
        guard actions.indices.contains(selection) else { return }
        // The RAW edits made against the action being left are written back
        // here, so switching the pop-up does not silently discard them. The
        // other boundary is the start of a run; there is deliberately no
        // third, because a continuous slider would write the file dozens of
        // times per drag.
        persistRawSettings()
        actionIndex = selection
        loadRaw(from: actions[selection].summary)
        for (index, knob) in Self.rawKnobs.enumerated() {
            if rawRows.indices.contains(index) { rawRows[index].setValue(rawSliderValues[index]) }
            if rawChecks.indices.contains(index) {
                rawChecks[index].state = knob.read(raw) != nil ? .on : .off
            }
        }
        whiteBalanceRow?.setSelected(isCustomWhiteBalance ? 1 : 0)
        lensRow?.setSelected(Self.flagIndex(raw.lensCorrection))
        highlightRow?.setSelected(Self.flagIndex(raw.highlightRecovery))
        applyRawEnablement()
        rawChanged()
        clearProblem()
    }

    @objc private func chooseInput(_ sender: Any?) {
        guard let url = chooseFolder(title: "Choose the folder to read") else { return }
        inputFolder = url
        let count = BatchRun.imageURLs(in: url).count
        show(url, in: inputLabel, suffix: " — \(count) image\(count == 1 ? "" : "s")")
        clearProblem()
    }

    @objc private func chooseOutput(_ sender: Any?) {
        guard let url = chooseFolder(title: "Choose the folder to write") else { return }
        outputFolder = url
        show(url, in: outputLabel, suffix: "")
        clearProblem()
    }

    private func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        // A nested modal session: the panel runs inside the Batch window's,
        // which AppKit supports, and which keeps the folder choice part of
        // this dialog rather than a sheet the run loop has to come back from.
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func show(_ url: URL, in label: NSTextField, suffix: String) {
        label.stringValue = url.path + suffix
        label.toolTip = url.path
    }

    /// The naming template is checked as it is typed, so `/`, `:` and a
    /// mistyped token are refused where they were entered rather than at the
    /// end of a run that produced one literal name for every file.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === templateField else { return }
        template = field.stringValue
        showProblem(BatchRun.templateProblem(template))
    }

    /// Shows a refusal in the card, or clears it — never a dismissed dialog
    /// the user has to reconstruct.
    ///
    /// The card is only resized when the label appears or disappears: it is
    /// one line in every message it can show, and resizing on every
    /// keystroke of live template validation would make the window twitch.
    private func showProblem(_ reason: String?) {
        let wasHidden = problemLabel.isHidden
        problemLabel.stringValue = reason ?? ""
        problemLabel.isHidden = reason == nil
        if wasHidden != problemLabel.isHidden, let card = setupCard { resize(to: card) }
    }

    private func clearProblem() {
        showProblem(nil)
    }

    /// Refuses a run: the same message, plus the beep every refusal in the
    /// app makes.
    private func refuse(_ reason: String) {
        showProblem(reason)
        NSSound.beep()
    }

    @objc private func cancelClicked(_ sender: Any?) {
        modal?.end(.cancel)
    }

    // MARK: - Starting the run

    @objc private func runClicked(_ sender: Any?) {
        guard actions.indices.contains(actionIndex) else { return }
        guard let input = inputFolder else {
            refuse("Choose an input folder.")
            return
        }
        guard let output = outputFolder else {
            refuse("Choose an output folder.")
            return
        }
        // The direct question — "is this the same directory?" — rather than
        // a path compare standing in for it, and the same test the per-file
        // containment guard uses, so there is one rule and one answer.
        guard !BatchRun.sameDirectory(input, output) else {
            refuse("Choose an output folder that is not the input folder.")
            return
        }
        if let problem = BatchRun.templateProblem(template) {
            refuse(problem)
            return
        }
        guard !BatchRun.imageURLs(in: input).isEmpty else {
            refuse("That folder holds no images Rasterize can open.")
            return
        }

        // The steps are read HERE, once, from the file the pop-up named —
        // the window itself holds only summaries. A file that summarised
        // cleanly and then will not decode (a malformed symbol, a non-finite
        // number deep in an argument) is refused with its own reason, before
        // anything is opened or written.
        var action: Action
        switch ActionLibrary.action(at: actions[actionIndex].url) {
        case .ok(let decoded): action = decoded
        case .broken(let file, let reason):
            refuse("\(file): \(reason)")
            return
        }
        persistRawSettings()
        // Set again rather than trusted from the library entry: when the
        // write above failed, the run still uses what the user chose.
        action.raw = raw.isAsShot ? nil : raw
        startRun(
            with: BatchSettings(
                action: action, inputFolder: input, outputFolder: output,
                format: exportOptions.selectedFormat, jpegQuality: exportOptions.quality,
                embedProfile: exportOptions.embedProfile,
                stripMetadata: exportOptions.stripMetadata,
                nameTemplate: template.trimmingCharacters(in: .whitespaces),
                overwrite: overwrite, stopOnError: stopOnError))
    }

    /// Writes the selected action's `raw` object back when it differs from
    /// what the library holds, so the next batch of the same folder — and
    /// any agent reading `list_actions` — sees the settings chosen here.
    ///
    /// A failure is remembered and reported at the top of the run report
    /// rather than raised as an alert: the run uses the in-memory settings
    /// either way, and interrupting a run that has just begun to say a
    /// preference was not filed away would be the louder half of the news.
    private func persistRawSettings() {
        guard actions.indices.contains(actionIndex) else { return }
        let entry = actions[actionIndex]
        let wanted = raw.isAsShot ? nil : raw
        guard entry.summary.raw != wanted else { return }
        // The whole action, because writing it back rewrites the file: the
        // summary knows the `raw` object but not the steps that must survive
        // the write. Read only when something actually changed, which is what
        // keeps switching the pop-up from decoding every action it passes.
        guard case .ok(var action) = ActionLibrary.action(at: entry.url) else {
            rawSaveNote =
                "note: the RAW develop settings could not be saved to “\(entry.summary.name)” "
                + "(its file could not be read) — the run still developed with them."
            return
        }
        action.raw = wanted
        do {
            try ActionLibrary.save(action)
            actions[actionIndex].summary.raw = wanted
        } catch {
            rawSaveNote =
                "note: the RAW develop settings could not be saved to “\(action.name)” "
                + "(\(error.localizedDescription)) — the run still developed with them."
        }
    }

    // MARK: - Run / Report pane

    private func startRun(with settings: BatchSettings) {
        let driver = BatchRun(settings: settings)
        install(makeRunCard(count: driver.files.count))
        driver.onProgress = { [weak self] number, total, name in
            self?.progressBar.doubleValue = Double(number - 1)
            self?.statusLabel.stringValue = "File \(number) of \(total) — \(name)"
        }
        driver.onFinish = { [weak self] report in
            self?.finished(report)
        }
        self.driver = driver
        driver.start()
    }

    private func makeRunCard(count: Int) -> NSView {
        statusLabel.font = DS.mono(12)
        statusLabel.textColor = DS.textMuted
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.stringValue = "Starting…"
        statusLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        progressBar.isIndeterminate = false
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = Double(max(count, 1))
        progressBar.doubleValue = 0
        progressBar.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        reportView.isEditable = false
        reportView.isRichText = false
        reportView.drawsBackground = false
        reportView.font = DS.mono(11)
        reportView.textColor = DS.textStrong
        reportView.textContainerInset = NSSize(width: 6, height: 6)
        reportView.autoresizingMask = [.width]
        reportView.textContainer?.widthTracksTextView = true
        reportScroll.documentView = reportView
        reportScroll.hasVerticalScroller = true
        reportScroll.autohidesScrollers = true
        reportScroll.drawsBackground = false
        reportScroll.borderType = .lineBorder
        reportScroll.isHidden = true
        reportScroll.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        reportScroll.heightAnchor.constraint(equalToConstant: 260).isActive = true

        let content = NSStackView(views: [statusLabel, progressBar, reportScroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12

        let stop = sheetCancelButton(target: self, action: #selector(stopClicked(_:)))
        stop.title = "Stop"
        stopButton = stop
        let done = StickerButton(
            title: "Done", style: .primary, target: self, action: #selector(doneClicked(_:)))
        // Hidden, not disabled: a hidden button takes no key equivalent, so
        // Return does nothing until the run is over and Done appears.
        done.isHidden = true
        doneButton = done
        let copy = StickerButton(
            title: "Copy Report", style: .secondary, target: self,
            action: #selector(copyReportClicked(_:)))
        copy.isHidden = true
        copyButton = copy
        return makeSheetView(
            title: "Batch", hint: nil, content: content,
            buttonRow: makeButtonRow(cancel: stop, apply: done, leading: [copy]),
            width: Self.cardWidth)
    }

    /// The report pane. One row per file, plus the headline that says
    /// whether the output folder holds a finished job or part of one.
    private func finished(_ report: BatchReport) {
        // Safe to release the driver here: the timer block holds a strong
        // reference for the duration of the tick that reached this.
        driver = nil
        progressBar.doubleValue = progressBar.maxValue
        // The headline can outrun one line — a halt names the file, the step
        // and the reason — so it carries itself as a tooltip too, and the
        // report below repeats it in full.
        statusLabel.stringValue = report.summary
        statusLabel.toolTip = report.summary
        var text = report.text()
        if let note = rawSaveNote { text = note + "\n\n" + text }
        reportView.string = text
        reportScroll.isHidden = false
        stopButton?.isHidden = true
        copyButton?.isHidden = false
        doneButton?.isHidden = false
        if let card = modal?.window?.contentView { resize(to: card) }
    }

    @objc private func stopClicked(_ sender: Any?) {
        guard let driver = driver else {
            modal?.end(.cancel)
            return
        }
        // Between files, never inside one: a core call cannot be
        // interrupted, and half a written file is worse than one more whole
        // one.
        statusLabel.stringValue = "Stopping after this file…"
        driver.cancel()
    }

    @objc private func doneClicked(_ sender: Any?) {
        modal?.end(.OK)
    }

    @objc private func copyReportClicked(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(reportView.string, forType: .string)
    }
}
