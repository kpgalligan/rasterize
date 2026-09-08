import AppKit

/// The colour-management and metadata tools, mirroring Image > Mode, Image
/// Size's Resolution field and the Export panel's two checkboxes:
///
/// | Handler | UI path it mirrors |
/// |---|---|
/// | `getColorProfile` | the status bar's profile and ppi segments, and what
///   the Assign/Convert sheets read |
/// | `assignProfile` | Image > Mode > Assign Profile… |
/// | `convertProfile` | Image > Mode > Convert to Profile… |
/// | `setResolution` | Image > Image Size…'s Resolution field with Resample off |
/// | `getMetadata` | no dialog — the packets the Export panel's Strip metadata checkbox governs |
///
/// The static field builders here are also what `get_document` and
/// `save_copy` report with, so the document summary and these tools can
/// never disagree about a profile name.
///
/// Every editing handler is ONE undo step and answers a core refusal in
/// band, as `changed: false` with a note rather than an error: a nil from
/// assign, convert or set_resolution means the document already looks like
/// that, or that one side of the transform is not a matrix/TRC profile — and
/// in none of those cases is retrying the identical call the right move for
/// a model.
///
/// The core answers all of them with the same undifferentiated nil, so each
/// handler asks the questions it CAN answer first — the bytes through
/// `RasterProfile.inspect`, the document through `profileIsConvertible` —
/// and the note that comes back names the real cause. That is the
/// `requireChannelBudget` pattern, for the same reason.
extension AgentServer {
    // MARK: - Reading

    /// get_color_profile: the document's colour space, whether Rasterize
    /// can convert with it, what the OPEN did, and the print size its ppi
    /// implies.
    func getColorProfile(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        var result = Self.colorProfileFields(doc, document)
        result.merge(Self.resolutionFields(doc)) { _, new in new }
        return try jsonResult(result)
    }

    /// get_metadata: which packets the document carries and how big they
    /// are — presence and size only, never a parsed EXIF dump.
    func getMetadata(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        var result: [String: Any] = [
            "exif": Self.packetField(doc, RZ_METADATA_EXIF),
            "xmp": Self.packetField(doc, RZ_METADATA_XMP),
            "iptc": Self.packetField(doc, RZ_METADATA_IPTC),
            "profile": doc.profileName,
            "on_open": Self.adoptionName(document.profileAdoption),
        ]
        result.merge(Self.resolutionFields(doc)) { _, new in new }
        // Three absent packets mean two different things, and only the
        // document knows which: a JPEG that carried none, or a file whose
        // container this build never walked.
        result.merge(Self.notCapturedField(document)) { _, new in new }
        return try jsonResult(result)
    }

    // MARK: - Editing

    /// assign_profile: RELABELS the document. Not one pixel number changes,
    /// so the picture changes appearance — the Photoshop distinction Assign
    /// and Convert exist to keep apart.
    func assignProfile(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let profile = try resolveProfile(a)
        let previous = doc.profileName
        // Asked BEFORE the edit, against the profile the document is leaving:
        // different bytes are not a different space (a camera's 3144-byte
        // HP/IEC sRGB blob against this build's 2568-byte one), and saying
        // the picture now looks different when nothing about it moved is
        // exactly the kind of claim a model acts on.
        let sameSpace = (doc.iccProfile).map {
            ColorProfileControls.describesCurrentSpace(profile.data, current: $0)
        } ?? false
        guard try editColor(document, "Assign Profile", { $0.assigningProfile(profile.data) })
        else {
            return try noOpColorResult(
                ["profile": previous],
                why: "the document is already tagged “\(previous)”.")
        }
        return try jsonResult([
            "ok": true, "changed": true,
            "profile": document.doc?.profileName ?? profile.name,
            "previous_profile": previous,
            "note": sameSpace
                ? "Pixel numbers were not touched, and the new profile describes the space the "
                    + "document was already in, so only the tag changed."
                : "Pixel numbers were not touched, so the picture now looks different.",
        ])
    }

    /// convert_profile: TRANSFORMS every layer's pixels into the new space
    /// so each layer keeps its appearance. Masks, alpha channels and layer
    /// descriptions are coverage, not colour, and are untouched — and so are
    /// layer-style and text-layer colours, which are AUTHORED sRGB and
    /// convert where they are used (a style's at composite time, a text
    /// layer's when it re-renders), so they keep their appearance too.
    ///
    /// The COMPOSITE is a different promise, and the note makes it honestly:
    /// a non-Normal blend mode, an adjustment layer or a blending style
    /// effect is computed from the numbers this changes, so such a document
    /// looks different afterwards.
    func convertProfile(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let profile = try resolveProfile(a)
        let previous = doc.profileName
        // Both halves of the transform are checked separately, so the note
        // names the side that is actually unconvertible — the core's single
        // nil covers three different situations, and "one of them" would send
        // a model guessing which.
        guard doc.profileIsConvertible else {
            return try noOpColorResult(
                ["profile": previous],
                why: "Rasterize cannot convert from “\(previous)” — it is not a matrix/TRC "
                    + "profile. assign_profile can still relabel the document.")
        }
        guard profile.convertible else {
            return try noOpColorResult(
                ["profile": previous],
                why: "Rasterize cannot convert into “\(profile.name)” — it is not a matrix/TRC "
                    + "profile. assign_profile can still relabel the document with it.")
        }
        // What the conversion is worth is a property of this stack, asked
        // before the edit for the same reason the sheet asks it: blend math,
        // an adjustment layer's parameters and a Blend If threshold are
        // evaluated ON the numbers being changed, so a layered composite
        // genuinely moves and "the picture looks the same" would be wrong.
        let appearance = ColorProfileControls.convertAppearanceSentence(doc)
        guard try editColor(
            document, "Convert to Profile", { $0.convertingToProfile(profile.data) })
        else {
            return try noOpColorResult(
                ["profile": previous],
                why: "“\(previous)” and “\(profile.name)” already describe the same space.")
        }
        return try jsonResult([
            "ok": true, "changed": true,
            "profile": document.doc?.profileName ?? profile.name,
            "previous_profile": previous,
            "note": "Every layer's pixels were transformed. " + appearance,
        ])
    }

    /// set_resolution: the print resolution ONLY — no pixel is resampled,
    /// only the print size follows.
    func setResolution(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard let x = doubleArg(a, "ppi_x") else {
            throw ToolError(message: "set_resolution requires ppi_x")
        }
        let y = doubleArg(a, "ppi_y") ?? x
        // 1…30000 ppi is the range the core sanitizes to, so refusing outside
        // it is the difference between telling the model its number was wrong
        // and silently clamping 0.5 to 1 and calling that a change.
        guard x.isFinite, y.isFinite, x >= 1, x <= 30000, y >= 1, y <= 30000 else {
            throw ToolError(message: "ppi_x and ppi_y must be between 1 and 30000")
        }
        let previous = doc.resolution
        guard try editColor(
            document, "Image Size", { $0.settingResolution(x: x, y: y) })
        else {
            return try noOpColorResult(
                Self.resolutionFields(doc),
                why: "the document is already at \(Self.ppi(previous.x)) × "
                    + "\(Self.ppi(previous.y)) ppi.")
        }
        var result: [String: Any] = ["ok": true, "changed": true]
        if let doc = document.doc {
            result.merge(Self.resolutionFields(doc)) { _, new in new }
        }
        result["note"] = "No pixel was resampled — only the print size changed."
        return try jsonResult(result)
    }

    // MARK: - Field builders shared with get_document and save_copy

    /// The document's colour space, for `get_document` and
    /// `get_color_profile` alike.
    static func colorProfileFields(
        _ doc: RasterDocument, _ document: ImageDocument
    ) -> [String: Any] {
        [
            "name": doc.profileName,
            // false means Rasterize can DISPLAY and re-embed the profile but
            // cannot transform with it (a LUT-based profile).
            "convertible": doc.profileIsConvertible,
            "on_open": adoptionName(document.profileAdoption),
        ]
    }

    /// The print resolution and the print size it implies.
    ///
    /// The inch figures are rounded to a thousandth: that is finer than any
    /// printer resolves and it keeps binary-float noise (8.000000000000002)
    /// out of the JSON a model reads back. `max(ppi, 1)` is a division
    /// guard only — the core clamps a stored ppi to at least 1.
    static func resolutionFields(_ doc: RasterDocument) -> [String: Any] {
        let ppi = doc.resolution
        return [
            "ppi_x": ppi.x,
            "ppi_y": ppi.y,
            "print_width_in": round(Double(doc.width) / max(ppi.x, 1) * 1000) / 1000,
            "print_height_in": round(Double(doc.height) / max(ppi.y, 1) * 1000) / 1000,
        ]
    }

    /// The metadata packets the document actually carries. Empty when it
    /// carries none, so `get_document` can omit the key entirely.
    static func metadataFields(_ doc: RasterDocument) -> [String: Any] {
        var fields: [String: Any] = [:]
        for (key, kind) in [
            ("exif", RZ_METADATA_EXIF), ("xmp", RZ_METADATA_XMP), ("iptc", RZ_METADATA_IPTC),
        ] {
            guard let bytes = doc.metadata(kind) else { continue }
            fields[key] = ["present": true, "bytes": bytes.count]
        }
        return fields
    }

    /// `metadata_not_captured: true` when this document's source container
    /// was never walked for packets, and nothing at all otherwise — a key
    /// that is absent on every ordinary document is one a model can read as
    /// a warning rather than as noise.
    ///
    /// It is deliberately NOT folded into `dropped`: that array names what
    /// the DOCUMENT held and the file did not, and we do not know which
    /// packets the source file had, only that we never looked.
    static func notCapturedField(_ document: ImageDocument) -> [String: Any] {
        guard document.metadataNotCaptured else { return [:] }
        return ["metadata_not_captured": true]
    }

    /// What a finished save wrote and what it did not — the core's own
    /// report, not a guess from a format table. A kind lands in `dropped`
    /// when the format cannot carry it, when it was too large for the
    /// format's segment, or when the call asked for it to be left out.
    ///
    /// `metadata_not_captured` rides along for a platform-decoded document
    /// (HEIC, a Live Photo): its source file's capture data never reached
    /// the document, so no bit can go missing and `dropped` alone would let
    /// the save look lossless. The Export panel's notice says the same thing
    /// in a sentence — `ExportCapabilities.droppedMessage`.
    static func savedFields(
        _ doc: RasterDocument, _ document: ImageDocument, report: RasterSaveReport
    ) -> [String: Any] {
        // Only what the document HOLDS is reported, so a file that never had
        // an EXIF block is never described as having lost one. A profile and
        // a resolution are always held — a document has both, always — so
        // those two rows are unconditional and land in `dropped` when the
        // format cannot carry them or the call asked for them to be left out.
        let kinds: [(name: String, bit: UInt32, held: Bool)] = [
            ("color_profile", RZ_CARRIES_PROFILE, true),
            ("exif", RZ_CARRIES_EXIF, doc.metadata(RZ_METADATA_EXIF) != nil),
            ("xmp", RZ_CARRIES_XMP, doc.metadata(RZ_METADATA_XMP) != nil),
            ("iptc", RZ_CARRIES_IPTC, doc.metadata(RZ_METADATA_IPTC) != nil),
            ("resolution", RZ_CARRIES_RESOLUTION, true),
        ]
        var wrote: [String] = []
        var dropped: [String] = []
        for kind in kinds where kind.held {
            if report.carries(kind.bit) {
                wrote.append(kind.name)
            } else {
                dropped.append(kind.name)
            }
        }
        var fields: [String: Any] = ["wrote": wrote, "dropped": dropped]
        fields.merge(notCapturedField(document)) { _, new in new }
        return fields
    }

    // MARK: - Shared pieces

    /// One colour edit, off the event path like every agent edit, with the
    /// core's refusal handed back rather than thrown. Returns false when the
    /// op answered nil — nothing would change — and rethrows anything else,
    /// so a real failure still reaches the model as an error. (The channel
    /// tools' `editChannels` is the same wrapper for the same reason.)
    private func editColor(
        _ document: ImageDocument, _ actionName: String,
        _ transform: (RasterDocument) -> RasterDocument?
    ) throws -> Bool {
        var refused = false
        do {
            try performGroupedEdit(document, actionName) { current in
                let out = transform(current)
                if out == nil { refused = true }
                return out
            }
        } catch let error as ToolError {
            guard refused else { throw error }
            return false
        }
        return true
    }

    /// The in-band "nothing changed" answer: no undo step opened and no byte
    /// moved, and saying so plainly is what lets a model carry on instead of
    /// retrying the identical call.
    private func noOpColorResult(_ fields: [String: Any], why: String) throws -> String {
        try jsonResult(
            fields.merging([
                "ok": true, "changed": false,
                "note": "Nothing changed: \(why) No undo step was added.",
            ]) { _, shared in shared })
    }

    /// A profile the caller named, already known to be one the core will
    /// accept: its bytes, the name to report, and whether Rasterize can
    /// transform INTO it (false for a LUT-based profile, which can still be
    /// assigned).
    private struct ResolvedProfile {
        let data: Data
        let name: String
        let convertible: Bool
    }

    /// The `profile` argument resolved to bytes: one of the two built-ins
    /// this build writes, or an `.icc`/`.icm` file on disk.
    ///
    /// The bytes are inspected HERE, before the core sees them, so a refusal
    /// can say *why* — the core answers a bare nil, which reads as "check
    /// the parameters" and sends a model retrying the same call. Everything
    /// this checks is something `rz_doc_assign_profile` also refuses, so
    /// after it returns, the ONLY remaining reason for a nil from assign is
    /// "the document already carries these exact bytes" — which is what the
    /// caller is then free to report.
    private func resolveProfile(_ a: [String: Any]) throws -> ResolvedProfile {
        let choice = (stringArg(a, "profile") ?? "srgb").lowercased()
        let data: Data
        switch choice {
        case "srgb":
            data = RasterProfile.builtin(.sRGB)
        case "display_p3", "displayp3", "p3":
            data = RasterProfile.builtin(.displayP3)
        case "file":
            let path = try requiredString(a, "path")
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let loaded = try? Data(contentsOf: url), !loaded.isEmpty else {
                throw ToolError(message: "Could not read a colour profile at \(url.path)")
            }
            data = loaded
        case let other:
            throw ToolError(
                message: "profile must be srgb, display_p3 or file (got \"\(other)\")")
        }
        // 16 MiB is the RZDC writer's per-blob cap, which the core enforces on
        // assign too so a document can never hold a profile the format would
        // refuse to save. Checking it here is what keeps the caller's "already
        // tagged that" note honest: without it a 20 MiB file would come back
        // as a bare nil and be reported as a no-op.
        let maxProfileBytes = 16 * 1024 * 1024
        guard data.count <= maxProfileBytes else {
            throw ToolError(
                message: "That colour profile is \(data.count) bytes — over the 16 MiB a "
                    + "Rasterize document can carry.")
        }
        let info = RasterProfile.inspect(data)
        switch info.kind {
        case .notICC:
            throw ToolError(message: "That file is not an ICC colour profile.")
        case .notRGB:
            throw ToolError(
                message: "“\(info.name)” is not an RGB profile — Rasterize documents are RGB, "
                    + "so Gray, CMYK and Lab profiles cannot be assigned.")
        case .notImageProfile:
            throw ToolError(
                message: "“\(info.name)” describes a colour transform rather than a colour "
                    + "space — it is a device-link, abstract or named-colour profile, so "
                    + "there is no way to interpret a document's pixels in it.")
        case .rgbUnconvertible:
            return ResolvedProfile(data: data, name: info.name, convertible: false)
        case .rgbMatrix:
            return ResolvedProfile(data: data, name: info.name, convertible: true)
        }
    }

    /// One metadata packet's presence and size.
    private static func packetField(_ doc: RasterDocument, _ kind: RzMetadataKind) -> [String: Any]
    {
        guard let bytes = doc.metadata(kind) else { return ["present": false, "bytes": 0] }
        return ["present": true, "bytes": bytes.count]
    }

    /// What the OPEN did, as the catalog's three words.
    private static func adoptionName(_ outcome: RasterAdoptOutcome) -> String {
        switch outcome {
        case .unchanged: return "unchanged"
        case .converted: return "converted"
        case .keptUnconvertible: return "kept"
        }
    }

    /// A ppi value for prose, without a trailing `.0` on the common case.
    ///
    /// Four decimals is the whole story: the core quantizes a stored ppi to
    /// four (the same `q4` the global light uses), so nothing finer exists to
    /// report — and trailing zeros are trimmed so a 300 ppi document reads
    /// "300", not "300.0000", in a sentence a model is meant to act on.
    private static func ppi(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))" }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
