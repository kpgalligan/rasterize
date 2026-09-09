import AppKit

/// The Actions window's `Edit JSON` sheet: the action as text, validated
/// through `Action.decode` before anything is written.
///
/// It is the escape hatch the brief asks for — "the user can edit the JSON
/// directly; a malformed action is refused with the reason, never crashed
/// on" — and the reason shown is `Action.decode`'s own sentence, verbatim
/// ("step 3: unknown tool \"blurr\"", "raw.exposure must be between -4 and 4
/// (got 9)"), because that message names both what is wrong and where.
///
/// A refusal does NOT dismiss: the text stays exactly as typed, with the
/// reason under it, so a fix is one edit away rather than a re-open and a
/// re-type.
///
/// This sheet knows nothing about where an action lives. `apply` is handed
/// the decoded action and the raw text and answers nil for "written", or the
/// sentence to show — which is what lets the same editor serve a saved
/// action's file, a broken file that has to be repaired in place, and the
/// live recording, which has no file at all.
final class ActionJSONSheetController: NSViewController {
    private let initialJSON: String
    private let sheetTitle: String
    private let sheetHint: String
    private let apply: (Action, String) -> String?

    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 596, height: 360))
    private let scroll = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(
        title: String, hint: String, json: String,
        apply: @escaping (Action, String) -> String?
    ) {
        self.sheetTitle = title
        self.sheetHint = hint
        self.initialJSON = json
        self.apply = apply
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ActionJSONSheetController does not support NSCoder")
    }

    override func loadView() {
        // Every automatic substitution is off. A JSON editor that turns "
        // into a curly quote produces a file its own decoder then refuses,
        // and the user would have no way to see why — the two glyphs look
        // nearly identical at 11 pt.
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.allowsUndo = true
        textView.font = DS.mono(11)
        textView.textColor = DS.textStrong
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 596, height: CGFloat.greatestFiniteMagnitude)
        textView.string = initialJSON

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        errorLabel.font = DS.sans(12)
        errorLabel.textColor = .systemOrange
        errorLabel.isEditable = false
        errorLabel.preferredMaxLayoutWidth = 596
        errorLabel.stringValue = ""
        errorLabel.isHidden = true

        let content = NSStackView(views: [scroll, errorLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        let row = makeButtonRow(
            cancel: cancelButton, apply: applyButton,
            leading: [sheetFootnote("validated before it is written")])
        // `makeButtonRow` makes Apply the default button, and a default
        // button swallows Return ahead of the first responder — which in a
        // multi-line JSON editor would mean the Return key could never open
        // a new line. Esc still cancels, as it does in every sheet here.
        applyButton.keyEquivalent = ""

        view = makeSheetView(
            title: sheetTitle, hint: sheetHint, content: content, buttonRow: row, width: 640)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 596),
            scroll.heightAnchor.constraint(equalToConstant: 360),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    @objc private func applyClicked(_ sender: Any?) {
        let text = textView.string
        switch Action.decode(Data(text.utf8)) {
        case .failure(let error):
            show(error.message)
        case .success(let action):
            if let refusal = apply(action, text) {
                show(refusal)
                return
            }
            dismiss(self)
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }

    /// Shows the refusal and beeps, without dismissing. The sheet grows to
    /// fit it, so a long message is never clipped away.
    private func show(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        NSSound.beep()
    }
}
