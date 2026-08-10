import AppKit

/// The Assistant tab of the right panel: a chat with the built-in agent
/// that edits the window's document through the shared tool dispatcher.
/// One session per panel (= per document window); Clear starts fresh.
final class AssistantPanelViewController: NSViewController {
    weak var document: ImageDocument?

    /// Called when the user clicks the Layers tab.
    var onShowLayers: (() -> Void)?

    private var session: AssistantSession?
    private var busy = false

    private let transcript = NSTextView()
    private let transcriptScroll = NSScrollView()
    private let inputField = NSTextField()
    private var sendButton: StickerButton!
    private let spinner = NSProgressIndicator()
    private var inputRow: NSStackView!
    private var keyBox: NSStackView!
    private let keyField = NSSecureTextField()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AssistantPanelViewController does not support NSCoder")
    }

    deinit {
        session?.close()
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: DS.panelWidth, height: 400))
        root.wantsLayer = true
        root.layer?.backgroundColor = DS.chromeBackground.cgColor

        let tabs = PanelTabsView(titles: ["Layers", "Assistant"], activeIndex: 1) {
            [weak self] index in
            if index == 0 { self?.onShowLayers?() }
        }
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = GhostButton(
            symbol: "arrow.counterclockwise", fallback: "↺", caption: nil,
            tooltip: "Clear the conversation", action: #selector(clearConversation(_:)))
        clearButton.target = self
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        transcript.isEditable = false
        transcript.isRichText = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 8, height: 10)
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true

        inputField.placeholderString = "Ask about or edit this image…"
        inputField.target = self
        inputField.action = #selector(sendClicked(_:))
        DSField.style(inputField)
        inputField.font = DS.sans(13)
        inputField.translatesAutoresizingMaskIntoConstraints = false

        sendButton = StickerButton(
            title: "Send", style: .primary, target: self, action: #selector(sendClicked(_:)))
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        inputRow = NSStackView(views: [inputField, sendButton])
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        inputRow.alignment = .centerY

        // API-key entry, shown instead of the input row until a key exists.
        let keyTitle = NSTextField(labelWithString: "")
        keyTitle.attributedStringValue = DS.microLabel("Anthropic API key")
        keyField.placeholderString = "sk-ant-…"
        DSField.style(keyField)
        let keySave = StickerButton(
            title: "Save Key", style: .primary, target: self, action: #selector(saveKey(_:)))
        let keyHint = NSTextField(
            wrappingLabelWithString:
                "Stored in your keychain. Launching with ANTHROPIC_API_KEY set also works.")
        keyHint.font = DS.mono(10)
        keyHint.textColor = DS.textFaint
        keyBox = NSStackView(views: [keyTitle, keyField, keySave, keyHint])
        keyBox.translatesAutoresizingMaskIntoConstraints = false
        keyBox.orientation = .vertical
        keyBox.alignment = .leading
        keyBox.spacing = 8
        keyField.widthAnchor.constraint(equalToConstant: DS.panelWidth - 24).isActive = true

        root.addSubview(tabs)
        root.addSubview(clearButton)
        root.addSubview(transcriptScroll)
        root.addSubview(spinner)
        root.addSubview(inputRow)
        root.addSubview(keyBox)

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),

            clearButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            transcriptScroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            transcriptScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: inputRow.topAnchor, constant: -10),

            spinner.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),

            inputRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            inputRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            inputRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            keyBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            keyBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            keyBox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
        refreshKeyState()
    }

    private func refreshKeyState() {
        let hasKey = APIKeyStore.resolve() != nil
        inputRow.isHidden = !hasKey
        keyBox.isHidden = hasKey
    }

    // MARK: - Actions

    @objc private func saveKey(_ sender: Any?) {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            NSSound.beep()
            return
        }
        if APIKeyStore.save(key) {
            keyField.stringValue = ""
            refreshKeyState()
            appendMeta("API key saved to the keychain.")
        } else {
            appendError("Could not save the key to the keychain.")
        }
    }

    @objc private func clearConversation(_ sender: Any?) {
        session?.close()
        session = nil
        setBusy(false)
        transcript.textStorage?.setAttributedString(NSAttributedString())
    }

    @objc private func sendClicked(_ sender: Any?) {
        if busy {
            // The sticker button reads "Stop" in this state.
            session?.cancel()
            return
        }
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard ensureSession() else { return }
        appendUser(text)
        inputField.stringValue = ""
        if session?.send(text) != true {
            appendError("The assistant is busy.")
        }
    }

    /// Creates the session on first use (needs the key and the document).
    private func ensureSession() -> Bool {
        if session != nil { return true }
        guard let apiKey = APIKeyStore.resolve() else {
            refreshKeyState()
            return false
        }
        let model =
            UserDefaults.standard.string(forKey: "AssistantModel") ?? "claude-sonnet-5"
        switch AssistantSession.open(apiKey: apiKey, model: model, system: systemPrompt()) {
        case .success(let session):
            session.onEvent = { [weak self] event in self?.handleEvent(event) }
            self.session = session
            return true
        case .failure(let error):
            appendError(error.message)
            return false
        }
    }

    private func systemPrompt() -> String {
        var context = "No document is open yet — use open_document or list_documents first."
        if let document = document, let doc = document.doc {
            let id = AgentServer.shared.documentID(for: document)
            context = """
                The user is looking at document id \(id): \"\(document.displayName ?? "Untitled")\" \
                (\(doc.width)×\(doc.height) px, \(doc.layerCount) layer(s)). Operate on this \
                document unless told otherwise — pass document_id \(id) on every tool call.
                """
        }
        return """
            You are the assistant built into Rasterize, a macOS layered image editor. You edit \
            the user's open image by calling tools; the user sees every change live and each \
            tool call is one undo step. \(context) Layer index 0 is the bottom layer. \
            Coordinates start at the canvas top-left corner with y increasing downward. Use the \
            render tool to look at the canvas before visual edits and again afterwards to \
            verify the result. Keep replies to a sentence or two; never repeat tool output \
            the user can already see.
            """
    }

    // MARK: - Events

    private func handleEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "turn_started":
            setBusy(true)
        case "assistant_text":
            appendAssistant(event["text"] as? String ?? "")
        case "tool_call":
            let name = event["name"] as? String ?? "?"
            appendMeta("⚙ \(name)\(argsSummary(event["arguments"]))")
        case "tool_result":
            if event["is_error"] as? Bool == true {
                appendMeta("   ✗ \(event["summary"] as? String ?? "failed")")
            }
        case "error":
            appendError(event["message"] as? String ?? "Unknown error.")
        case "turn_finished":
            setBusy(false)
        default:
            break
        }
    }

    private func argsSummary(_ arguments: Any?) -> String {
        guard let arguments = arguments as? [String: Any], !arguments.isEmpty else {
            return ""
        }
        let parts = arguments
            .filter { $0.key != "document_id" }
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: ", ")
        guard !parts.isEmpty else { return "" }
        return " (\(String(parts.prefix(70))))"
    }

    private func setBusy(_ value: Bool) {
        busy = value
        sendButton.title = value ? "Stop" : "Send"
        sendButton.needsDisplay = true
        if value {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    // MARK: - Transcript

    private func append(_ text: String, font: NSFont, color: NSColor, spacingAbove: CGFloat) {
        guard let storage = transcript.textStorage else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = spacingAbove
        paragraph.lineSpacing = 2
        let line = NSAttributedString(
            string: (storage.length > 0 ? "\n" : "") + text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        storage.append(line)
        transcript.scrollToEndOfDocument(nil)
    }

    private func appendUser(_ text: String) {
        guard let storage = transcript.textStorage else { return }
        if storage.length > 0 {
            append("", font: DS.sans(4), color: .clear, spacingAbove: 0)
        }
        append(text, font: DS.sans(13, weight: .semibold), color: DS.textStrong, spacingAbove: 8)
    }

    private func appendAssistant(_ text: String) {
        append(text, font: DS.sans(13), color: DS.textStrong, spacingAbove: 6)
    }

    private func appendMeta(_ text: String) {
        append(text, font: DS.mono(11), color: DS.textFaint, spacingAbove: 4)
    }

    private func appendError(_ text: String) {
        append(text, font: DS.sans(12), color: .systemRed, spacingAbove: 6)
    }
}
