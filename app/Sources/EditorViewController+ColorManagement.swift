import AppKit

/// Image > Mode: the two profile commands, plus the validation the frozen
/// editor delegates to them. The third item, Working Space, is an app-wide
/// PREFERENCE and lives on `AppDelegate` — it must stay usable with no
/// document open, which is exactly when a document-scoped responder does
/// not exist.
///
/// The sheets choose; this file commits and validates. `AssignProfile…`
/// commits inside its own dialog (one `applyEdit`, no preview to unwind),
/// while Convert hands its choice back here — the
/// `EditorViewController+ChannelMath.applyImage` shape — so the conversion
/// re-runs on the document's CURRENT handle rather than on the one the
/// sheet previewed.
extension EditorViewController {
    /// Image > Mode > Assign Profile… — RELABELS the document: the pixel
    /// numbers do not change, so the picture changes appearance.
    @objc func assignProfile(_ sender: Any?) {
        guard let document = document, let sheet = AssignProfileSheetController(document: document)
        else {
            NSSound.beep()
            return
        }
        presentAsSheet(sheet)
    }

    /// Image > Mode > Convert to Profile… — TRANSFORMS every layer's pixels
    /// so the picture looks the same in the new space.
    @objc func convertToProfile(_ sender: Any?) {
        guard let sheet = ConvertProfileSheetController(editor: self) else {
            NSSound.beep()
            return
        }
        presentAsSheet(sheet)
    }

    /// Commits `convertingToProfile` as ONE undo step.
    ///
    /// The conversion re-runs against the document's CURRENT handle inside
    /// the transform rather than the handle the sheet previewed, so an edit
    /// that slipped in while the dialog was open survives — the rule every
    /// live-preview sheet follows.
    ///
    /// It goes through `applyEdit`, NOT `applyRasterizingEdit`, and that is
    /// deliberate: a profile conversion is a whole-document
    /// reinterpretation, like a rotate, not a destructive local edit. A text
    /// or shape layer's meta still describes its pixels afterwards, because
    /// re-rendering it authors its sRGB colour into the document's space —
    /// the same move the conversion just made — so there is nothing for the
    /// user to be asked about. The agent's `convert_profile` takes the same
    /// path (`performGroupedEdit`, not `performPixelEdit`), so the two
    /// cannot drift.
    ///
    /// A nil result — the profiles describe the same space, or one of them
    /// is not a matrix/TRC profile — beeps inside `applyEdit` and registers
    /// no undo step. The sheet disables Apply for all three cases first and
    /// says which one it is, asking the core the same same-space question
    /// this call would (`RasterProfile.describesSameSpace`) rather than
    /// comparing profile bytes, which would leave Apply live for a different
    /// blob describing the document's own space.
    func commitProfileConversion(_ choice: ProfileChoice) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        let bytes = choice.data
        document.applyEdit("Convert to Profile") { $0.convertingToProfile(bytes) }
    }

    /// Enablement for the two items above.
    ///
    /// **Convert to Profile stays ENABLED for a document whose profile
    /// cannot be converted from.** A LUT-based (A2B/B2A) profile is a real
    /// profile Rasterize displays, embeds and can relabel — only the
    /// transform is unavailable — and a greyed-out menu item is the one form
    /// of refusal that cannot say so or point at Assign. The sheet opens
    /// with Apply disabled and the reason spelled out instead, which is the
    /// four-outcome policy's own answer for this document.
    func validateColorItem(_: NSValidatedUserInterfaceItem) -> Bool { true }
}
