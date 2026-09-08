import AppKit

/// Image > Mode > Convert to Profile…: transform every layer's pixels into
/// another space so the picture looks the same.
///
/// The counterpart of Assign, and the reverse trade: Convert changes the
/// pixel NUMBERS so that what the eye sees does not change. Only the layers
/// are converted — masks, alpha channels and layer descriptions are
/// coverage, not colour — and a conversion into a smaller gamut clips, which
/// is the one thing worth previewing here and why this sheet has a live
/// preview at all.
///
/// "What the eye sees does not change" is true of each LAYER and not of
/// every composite, and the note says which this document is: blend math, an
/// adjustment layer's parameters and a Blend If threshold are all evaluated
/// on the numbers being changed, so such a stack visibly moves — correctly,
/// and exactly as it does in Photoshop, but not silently.
/// `ColorProfileControls.appearanceDependsOnNumbers` is the question.
///
/// Three refusals live in the copy rather than in a disabled menu item,
/// because a beep cannot tell them apart: a document whose own profile is
/// LUT-based cannot be converted FROM, a loaded LUT-based profile cannot be
/// converted INTO, and a destination that describes the space the document
/// is already in has nothing to convert. The first two are real ICC profiles
/// Rasterize will happily display, embed and assign — it is only the
/// transform that needs a matrix/TRC model — so the sheet names the reason
/// and points at Assign.
///
/// The third is the one that has to be asked of the CORE. "Is this the space
/// we are in?" is not "are these the same bytes": the "sRGB IEC61966-2.1"
/// blob most cameras and Photoshop embed is 3144 bytes against the built-in
/// sRGB's 2568 and describes exactly the same space, so a byte comparison
/// lights Apply up for a conversion the core then refuses — a dismissed
/// sheet and an unexplained beep. `RasterProfile.describesSameSpace` asks the
/// question the core answers.
final class ConvertProfileSheetController: NSViewController {
    private weak var editor: EditorViewController?
    private weak var canvas: ImageCanvasView?
    /// The handle the preview runs on, captured when the sheet opened: the
    /// PreviewRenderer closure runs on a background queue and must never
    /// reach into live document state (`AdjustSheetController`'s `baseDoc`
    /// rule). Apply re-runs the conversion on the document's CURRENT handle.
    private let baseDoc: RasterDocument
    private let currentProfile: Data
    private let currentName: String
    /// Whether the core can convert FROM this document's profile. False for
    /// a LUT-based (A2B/B2A) profile, which is kept, displayed and
    /// re-embedded all the same.
    private let sourceIsConvertible: Bool

    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let note = ColorProfileControls.noteLabel()
    private var applyButton: NSButton!
    private let renderer = PreviewRenderer()

    /// The profile the popup names, and what the core makes of it. The kind
    /// and the same-space answer are stored rather than recomputed: each
    /// costs a parse of the blob, and they only ever change when the
    /// selection does.
    private var choice: ProfileChoice
    private var choiceKind: RasterProfileKind
    /// Whether converting into `choice` would change nothing — the core's
    /// own question, asked through `RasterProfile.describesSameSpace`.
    private var choiceIsCurrentSpace: Bool

    /// nil when there is no document, or when its profile cannot be read —
    /// a document always has one, so that means the read failed and the
    /// sheet has nothing truthful to convert from. The caller beeps.
    init?(editor: EditorViewController) {
        guard let doc = editor.document?.doc, let profile = doc.iccProfile, !profile.isEmpty
        else { return nil }
        self.editor = editor
        self.canvas = editor.canvas
        self.baseDoc = doc
        self.currentProfile = profile
        self.currentName = doc.profileName
        self.sourceIsConvertible = doc.profileIsConvertible
        // Opens on the document's own profile, so the sheet starts on the
        // identity: Apply is disabled until a different space is picked, and
        // the canvas needs no first preview because it is already showing
        // exactly what that selection would produce.
        let initial =
            WorkingSpace.allCases.first { $0.profileData == profile }
            .map { ProfileChoice.builtin($0) } ?? ProfileChoice.file(profile, doc.profileName)
        self.choice = initial
        // The opening selection IS the document's profile, and the core has
        // already classified that one: `profileIsConvertible` is exactly the
        // matrix/TRC question, so the blob need not be parsed again here —
        // and neither does the same-space question, whose answer for a
        // profile against itself is yes.
        self.choiceKind = doc.profileIsConvertible ? .rgbMatrix : .rgbUnconvertible
        self.choiceIsCurrentSpace = true
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConvertProfileSheetController does not support NSCoder")
    }

    override func loadView() {
        ColorProfileControls.fillProfiles(
            profilePopup, current: currentProfile, currentName: currentName)
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))

        let grid = NSGridView(views: [
            [fieldLabel("Destination:"), profilePopup]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        let content = NSStackView(views: [grid, note])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        syncControls()
        view = makeSheetView(
            title: "Convert to profile",
            hint: "Convert transforms every layer's pixels into another space, so each layer "
                + "keeps its appearance while its numbers change. Layer masks, alpha channels "
                + "and layer descriptions are coverage, not colour, and are left exactly as "
                + "they are.",
            content: content,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("one undo step")]))
    }

    // MARK: - State

    /// False when the document's profile cannot be converted from, when the
    /// selected profile cannot be converted into, and when the selection
    /// describes the space the document is already in — the three cases the
    /// core answers with the same bare nil, and which the note tells apart.
    private var canApply: Bool {
        guard sourceIsConvertible, choiceKind == .rgbMatrix else { return false }
        return !choiceIsCurrentSpace
    }

    /// The line under the popup. It carries the refusals in full, because it
    /// is the one label in the card that grows to fit a sentence and the one
    /// place a user can find out why Apply is grey.
    private var noteText: String {
        guard sourceIsConvertible else {
            return "Rasterize cannot convert from “\(currentName)” — it is not a matrix/TRC "
                + "profile. Assign Profile can still relabel the document."
        }
        guard choiceKind == .rgbMatrix else {
            return "Rasterize cannot convert into “\(choice.name)” — it is not a matrix/TRC "
                + "profile. Assign Profile can still relabel the document."
        }
        guard !choiceIsCurrentSpace else {
            // Two spellings of one refusal: the same profile, and a
            // different profile for the same space. Naming both sides in the
            // second case is the whole point — the two names are often
            // identical, and a user who picked a profile off disk deserves
            // to be told that it lands where the document already is.
            return choice.data == currentProfile
                ? "This document is already in “\(currentName)”, so there is nothing to convert."
                : "“\(choice.name)” and “\(currentName)” already describe the same colour "
                    + "space, so there is nothing to convert."
        }
        // What "the picture looks the same" is actually worth is a property
        // of THIS stack, not of the conversion: blend math, an adjustment's
        // parameters and a Blend If threshold are evaluated on the numbers
        // being changed, so a layered composite genuinely moves. The sheet
        // says which case the document is in rather than promising the
        // pleasant one — the live preview behind it is showing the truth
        // either way.
        return "Every layer's pixels move from “\(currentName)” to “\(choice.name)”. "
            + ColorProfileControls.convertAppearanceSentence(baseDoc)
            + " Layer-style and text colours are authored in sRGB and convert where they are "
            + "used rather than here, so their own colours are unaffected."
    }

    private func syncControls() {
        note.stringValue = noteText
        applyButton.isEnabled = canApply
    }

    // MARK: - Preview

    /// The document as the conversion would leave it, tagged with the
    /// DESTINATION profile so the canvas draws it through the space its new
    /// numbers belong to — which is the whole point: a correct conversion
    /// looks unchanged, and only the clipped colours move.
    ///
    /// A nil result clears the preview and puts the real document back on
    /// screen, which is the honest picture of "this would change nothing".
    private func requestPreview() {
        guard canApply else {
            // Cleared THROUGH the renderer, not by assigning the canvas
            // directly: a render already in flight still delivers its
            // result, and only a request queued behind it is guaranteed to
            // land last.
            renderer.request { nil }
            return
        }
        let bytes = choice.data
        let source = baseDoc
        renderer.request {
            guard let converted = source.convertingToProfile(bytes) else { return nil }
            return converted.flattened()?.makeCGImage(in: ColorProfile.space(for: bytes))
        }
    }

    // MARK: - Actions

    @objc private func profileChanged(_ sender: Any?) {
        ColorProfileControls.resolveSelection(
            profilePopup, presenter: self, previous: choice
        ) { [weak self] picked in
            guard let self = self else { return }
            self.choice = picked
            self.choiceKind = picked.kind
            self.choiceIsCurrentSpace = ColorProfileControls.describesCurrentSpace(
                picked.data, current: self.currentProfile)
            self.syncControls()
            self.requestPreview()
        }
    }

    @objc private func applyClicked(_ sender: Any?) {
        guard canApply else {
            NSSound.beep()
            return
        }
        let choice = self.choice
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        // The commit lives in the editor's extension, not here: the sheet
        // chooses, `commitProfileConversion` re-runs the conversion on the
        // document's current handle as one undo step.
        editor?.commitProfileConversion(choice)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}
