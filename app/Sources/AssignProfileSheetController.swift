import AppKit

/// Image > Mode > Assign Profile…: relabel the document without touching a
/// pixel.
///
/// Assign is not Convert, and the sheet's whole job is keeping the two
/// apart — the distinction Photoshop draws and the GIMP study insists on.
/// Assign leaves every pixel NUMBER exactly where it is and changes what
/// those numbers mean, so the picture changes appearance — unless the new
/// profile describes the space the document is already in, which is the
/// common case of retagging a camera JPEG's 3144-byte HP/IEC sRGB blob with
/// this build's own, and which the note tells apart. Convert changes
/// the numbers so the picture does not. Nothing here previews, because
/// there is nothing to preview about the pixels: what changes is the space
/// the canvas already draws them through, and the note under the popup says
/// so in words.
///
/// The popup itself is `ColorProfileControls`, shared with the Convert
/// sheet, so the two can never offer different profiles.
final class AssignProfileSheetController: NSViewController {
    private let document: ImageDocument
    /// The profile the document carried when the sheet opened, and its
    /// name. Captured once: a sheet blocks every edit action behind it, so
    /// this is still the document's profile when Apply runs, and reading it
    /// once keeps the note and the Apply test talking about the same bytes.
    private let currentProfile: Data
    private let currentName: String
    /// What the OPEN did to this document's colour — never updated by a
    /// later Assign or Convert, so it is the truth about how the document
    /// got here, which is exactly what someone reaching for Assign wants to
    /// know.
    private let adoption: RasterAdoptOutcome

    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let note = ColorProfileControls.noteLabel()
    private var applyButton: NSButton!

    /// The profile the popup names. Kept beside the popup because the Load
    /// row has to be restorable: a cancelled open panel puts the selection
    /// back on this one.
    private var choice: ProfileChoice
    /// Whether the selection describes the space the document is already in.
    /// Stored rather than recomputed: it costs a parse of the blob, and it
    /// only changes when the selection does.
    private var choiceIsCurrentSpace: Bool

    /// nil when the document's profile cannot be read — a document always
    /// has one, so that means the read failed and the sheet has nothing
    /// truthful to say. The caller beeps rather than presenting a dialog
    /// that would guess.
    init?(document: ImageDocument) {
        guard let doc = document.doc, let profile = doc.iccProfile, !profile.isEmpty else {
            return nil
        }
        self.document = document
        self.currentProfile = profile
        self.currentName = doc.profileName
        self.adoption = document.profileAdoption
        // The document's own profile is the starting selection, so opening
        // the sheet and pressing Apply cannot change anything by accident.
        // A built-in is named as a built-in — the popup shows "sRGB", not
        // the blob's own "sRGB IEC61966-2.1" — so the row and the note agree.
        self.choice =
            WorkingSpace.allCases.first { $0.profileData == profile }
            .map { ProfileChoice.builtin($0) } ?? .file(profile, doc.profileName)
        // The opening selection IS the document's profile, so the same-space
        // question needs no parse to answer here.
        self.choiceIsCurrentSpace = true
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AssignProfileSheetController does not support NSCoder")
    }

    override func loadView() {
        ColorProfileControls.fillProfiles(
            profilePopup, current: currentProfile, currentName: currentName)
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))

        let grid = NSGridView(views: [
            [fieldLabel("Profile:"), profilePopup]
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
            title: "Assign profile",
            hint: "Assign relabels the document: the pixel numbers stay exactly where they "
                + "are and the space they are read in changes.",
            content: content,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("one undo step")]))
    }

    // MARK: - State

    /// False while the selection is the profile the document already
    /// carries: `assigningProfile` refuses that outright, and a dialog that
    /// changes nothing must not mint an undo step.
    private var canApply: Bool { choice.data != currentProfile }

    /// The two sentences under the popup: what the document is now (and how
    /// it got that way), then what Apply would do about it.
    private var noteText: String {
        let opening = "This document is tagged “\(currentName)”. "
            + ColorProfileControls.adoptionSentence(adoption)
        guard canApply else {
            // Deliberately does NOT repeat the selected name: the popup's
            // short "sRGB" and the profile's own "sRGB IEC61966-2.1" are the
            // same profile, and printing both would read as two.
            return opening + " The popup names that same profile, so there is nothing to "
                + "apply."
        }
        // Different BYTES are not a different space: an ordinary camera
        // JPEG carries the 3144-byte HP/IEC "sRGB IEC61966-2.1" blob, and
        // tagging it with this build's own sRGB is a relabel that changes
        // the name in the status bar and nothing a user can see. Saying
        // "the picture will look different" there is simply false.
        guard !choiceIsCurrentSpace else {
            return opening + " Applying tags it “\(choice.name)” instead, which describes the "
                + "space it is already in — the tag changes and the picture does not."
        }
        return opening + " Applying tags it “\(choice.name)” instead — the same pixel "
            + "numbers, read as a different space, so the picture will look different."
    }

    private func syncControls() {
        note.stringValue = noteText
        applyButton.isEnabled = canApply
    }

    // MARK: - Actions

    @objc private func profileChanged(_ sender: Any?) {
        ColorProfileControls.resolveSelection(
            profilePopup, presenter: self, previous: choice
        ) { [weak self] picked in
            guard let self = self else { return }
            self.choice = picked
            self.choiceIsCurrentSpace = ColorProfileControls.describesCurrentSpace(
                picked.data, current: self.currentProfile)
            self.syncControls()
        }
    }

    @objc private func applyClicked(_ sender: Any?) {
        guard canApply else {
            NSSound.beep()
            return
        }
        // Values into locals, then dismiss, then commit — every sheet's
        // order, so the edit never lands under a dialog that is still up.
        let bytes = choice.data
        dismiss(self)
        // `assigningProfile` answers nil for bytes the document already
        // carries, which `applyEdit` turns into a beep and no undo step.
        document.applyEdit("Assign Profile") { $0.assigningProfile(bytes) }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}
