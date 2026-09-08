import AppKit

/// What an export format is ABLE to carry, and what a finished save
/// actually carried — the two questions the Export panel's checkboxes and
/// its after-the-fact notice ask.
///
/// The capability answers come from the core (`rz_format_carries`), never
/// from a table restated here: the UI and the writer must not be able to
/// disagree about whether a PNG can hold IPTC. The only numbers spelled out
/// below are JPEG's own segment arithmetic, and they are used ONLY to WORD a
/// message — what actually reached the file is the core's report and nothing
/// else, so a wording rule that ever fell out of step could make a sentence
/// vaguer, never wrong.
enum ExportCapabilities {

    /// Which of the export panel's two checkboxes a question is about. The
    /// boxes ask different things of the same capability word, so every
    /// message builder takes one.
    enum Option {
        /// "Embed colour profile".
        case colorProfile
        /// "Strip metadata" — the EXIF, XMP and IPTC packets together.
        case metadata
    }

    // MARK: - What a format is able to carry

    /// Whether `format` can embed an ICC profile at all.
    static func canEmbedProfile(_ format: ExportFormat) -> Bool {
        RasterProfile.carried(by: format.rzFormat) & RZ_CARRIES_PROFILE != 0
    }

    /// Whether `format` can carry any of the three metadata packets. False
    /// means the Strip metadata checkbox has nothing to strip.
    static func canCarryMetadata(_ format: ExportFormat) -> Bool {
        let bits = RasterProfile.carried(by: format.rzFormat)
        return bits & (RZ_CARRIES_EXIF | RZ_CARRIES_XMP | RZ_CARRIES_IPTC) != 0
    }

    // MARK: - The checkboxes' copy

    /// Why `option`'s checkbox is greyed for `format`, as its tooltip; nil
    /// exactly when the box is live, so a caller can write
    /// `box.isEnabled = reason == nil` and use `carriedNote` for the rest.
    static func disabledReason(_ format: ExportFormat, for option: Option) -> String? {
        let name = proseName(format)
        switch option {
        case .colorProfile:
            guard !canEmbedProfile(format) else { return nil }
            // Worth saying what the silence means: an untagged file is read
            // as sRGB by everything, so a P3 document exported here changes
            // appearance elsewhere.
            return "\(name) cannot embed a colour profile. Readers will assume sRGB."
        case .metadata:
            guard !canCarryMetadata(format) else { return nil }
            let all = list(packets.map { $0.label }, conjunction: "or")
            return "\(name) carries no \(all), so there is nothing to strip."
        }
    }

    /// What `format` does carry, as the live checkbox's tooltip. Always a
    /// sentence: a checkbox that is on by default should still be able to
    /// say what turning it off costs.
    static func carriedNote(_ format: ExportFormat, for option: Option) -> String {
        let name = proseName(format)
        switch option {
        case .colorProfile:
            var note = "The exported \(name) carries the document's colour profile, "
                + "so other applications see the colours this document shows."
            if format == .tiff {
                // The core's own documented limit, said where a user would
                // otherwise meet it as a mystery: the tag is written and
                // other applications read it, but this build's TIFF decoder
                // never surfaces it on the way back in.
                note += " Reopening it here assumes sRGB — the TIFF decoder "
                    + "this build uses never surfaces the tag."
            }
            return note
        case .metadata:
            let bits = RasterProfile.carried(by: format.rzFormat)
            let carried = packets.filter { bits & $0.bit != 0 }.map { $0.label }
            let missing = packets.filter { bits & $0.bit == 0 }.map { $0.label }
            let head = "\(name) carries \(list(carried))"
            // "but not XMP or IPTC" — a negated list takes "or", which is
            // why the joiner asks for its conjunction.
            let caveat = missing.isEmpty ? "." : ", but not \(list(missing, conjunction: "or"))."
            let it = carried.count == 1 ? "it" : "them"
            return head + caveat + " Strip \(it) to publish a file with no capture data."
        }
    }

    // MARK: - After the save

    /// What the document held that the written file does not, as one
    /// informational message; nil when everything survived.
    ///
    /// `embedProfile` and `stripMetadata` are what the caller ASKED FOR:
    /// data left out on purpose is not a loss to report, and a caller that
    /// nags about the checkbox the user just ticked will be ignored the one
    /// time it has something to say. They default to the export panel's own
    /// defaults — "nothing was deliberately excluded" — which is the only
    /// honest reading of a call that does not mention them; a caller that
    /// offers the checkboxes should pass what the user chose.
    ///
    /// The report is the authority on WHAT was dropped. This function only
    /// decides WHY, and it distinguishes three causes: the format has
    /// nowhere to put the thing, the packet is larger than the one JPEG
    /// segment it has to live in, or the writer refused a packet it could
    /// not vouch for.
    ///
    /// `metadataNotCaptured` is the fourth cause and the only one the report
    /// cannot see: a document decoded by the platform (HEIC, a Live Photo
    /// frame) never had its container walked, so packets its source file
    /// carries are absent from the document itself and no bit can go
    /// missing. Saying nothing would let such an export look lossless.
    static func droppedMessage(
        _ doc: RasterDocument, report: RasterSaveReport, format: ExportFormat,
        embedProfile: Bool = true, stripMetadata: Bool = false,
        metadataNotCaptured: Bool = false
    ) -> String? {
        var lost: [String] = []
        if embedProfile, !report.carries(RZ_CARRIES_PROFILE),
           let clause = profileClause(doc, format)
        {
            lost.append(clause)
        }
        if !stripMetadata {
            for packet in packets {
                // The bit is asked first: a packet that DID travel is never
                // copied out of the core just to be counted.
                guard !report.carries(packet.bit), let held = doc.metadata(packet.kind) else {
                    continue
                }
                lost.append(packetClause(packet, held: held.count, format: format))
            }
            // Only worth saying for a format that could have carried the
            // packets: telling someone exporting a GIF that capture data was
            // never read in names the wrong reason for its absence.
            if metadataNotCaptured, canCarryMetadata(format) {
                lost.append(
                    "Rasterize reads EXIF, XMP and IPTC from JPEG and PNG only, so any capture "
                        + "data this document's source file carried was never read in and "
                        + "could not travel out.")
            }
        }
        // The resolution is document state, not something inherited, so
        // neither checkbox governs it. It is only worth a line when the
        // document actually says something: every document has a ppi, and
        // announcing the loss of the 72 ppi default on every TIFF export
        // would be noise around the cases that matter.
        if !report.carries(RZ_CARRIES_RESOLUTION), let ppi = statedResolution(doc) {
            lost.append(resolutionClause(ppi, format))
        }
        guard !lost.isEmpty else { return nil }
        return (["The \(proseName(format)) was written. What did not travel with it:"]
            + lost.map { "• " + $0 }).joined(separator: "\n")
    }

    // MARK: - Causes

    /// Why the profile is missing from a file that was asked to embed one.
    /// Only two things can do it: the format has no slot, or the blob is
    /// too big for JPEG's 255 APP2 chunks.
    ///
    /// nil when nothing was actually lost. A file with no profile IS read as
    /// sRGB, so a document already in sRGB loses nothing by being written to
    /// a format with no slot — and that is the most ordinary document there
    /// is, which would otherwise make every GIF and BMP export raise a modal
    /// alert saying nothing. `statedResolution` skips the 72 ppi default for
    /// the same reason; this is the same rule for the other piece of
    /// always-present document state. (The Export panel's disabled checkbox
    /// has already stated the format's limit in its tooltip.)
    private static func profileClause(_ doc: RasterDocument, _ format: ExportFormat) -> String? {
        let name = proseName(format)
        guard canEmbedProfile(format) else {
            guard !isSRGB(doc) else { return nil }
            return "\(name) cannot embed a colour profile, so the file will be read as sRGB."
        }
        let size = doc.iccProfile.map { byteSize($0.count) } ?? "too large"
        return "The colour profile is \(size) — more than a JPEG's 255 profile chunks can hold."
    }

    /// Whether the document is in sRGB — the space a profile-less file is
    /// read as. Asked of the core, not of the bytes: an ordinary camera JPEG
    /// carries its own 3144-byte sRGB blob, and that document is as
    /// untroubled by a missing profile as one carrying the built-in. False
    /// for a profile the core cannot model, whose loss is real.
    private static func isSRGB(_ doc: RasterDocument) -> Bool {
        guard let profile = doc.iccProfile else { return false }
        let srgb = RasterProfile.builtin(.sRGB)
        return profile == srgb || RasterProfile.describesSameSpace(profile, srgb)
    }

    /// Why the document's print resolution is missing from the file.
    ///
    /// TIFF gets its own sentence because "nowhere to record it" would
    /// understate what lands in the file: the encoder crate writes its own
    /// XResolution 1/1, YResolution 1/1, ResolutionUnit "none", and
    /// applications that read that literally place the image at 1 dpi. The
    /// bit is clear because nothing in the file states THIS document's ppi,
    /// which is true — but silence is not what the file contains.
    private static func resolutionClause(_ ppi: String, _ format: ExportFormat) -> String {
        guard format == .tiff else {
            return "\(proseName(format)) has nowhere to record the \(ppi) print resolution."
        }
        return "TIFF files written here state no print resolution — they carry the encoder's "
            + "own 1/1 default, which some applications read as 1 dpi rather than as the "
            + "\(ppi) this document prints at."
    }

    /// Why one packet the document holds is missing from the written file.
    private static func packetClause(_ packet: Packet, held: Int, format: ExportFormat)
        -> String
    {
        let name = proseName(format)
        guard RasterProfile.carried(by: format.rzFormat) & packet.bit != 0 else {
            return "\(name) has nowhere to put \(packet.indefinite)."
        }
        if format == .jpeg, held + packet.jpegIdentifier > jpegSegmentPayload {
            return "The \(packet.shortName) is \(byteSize(held)) "
                + "— larger than a JPEG segment can hold."
        }
        return packet.refusal
    }

    /// The document's print resolution as a phrase, or nil when it is the
    /// 72 ppi default and therefore says nothing worth preserving.
    private static func statedResolution(_ doc: RasterDocument) -> String? {
        let (x, y) = doc.resolution
        // The core quantizes ppi to four decimals, so a value that came back
        // from it is exactly comparable at that scale.
        let epsilon = 0.0001
        guard abs(x - 72) > epsilon || abs(y - 72) > epsilon else { return nil }
        // Spelled by `PrintSize`, which the status bar also reads, so the
        // two readouts of one document's resolution cannot disagree.
        return PrintSize.resolutionText((x: x, y: y))
    }

    // MARK: - The packets, as a sentence talks about them

    /// One preserved packet: its capability bit, its names in prose, and
    /// the two things that can keep it out of a file that could hold it.
    private struct Packet {
        let kind: RzMetadataKind
        let bit: UInt32
        /// The bare name, for the tooltip's list of three.
        let label: String
        /// What it is called mid-sentence.
        let shortName: String
        /// The same with an article, for "…has nowhere to put an XMP packet".
        let indefinite: String
        /// Bytes of identifier the packet shares its one JPEG segment with:
        /// `Exif\0\0`, `http://ns.adobe.com/xap/1.0/\0`, `Photoshop 3.0\0`.
        /// Facts about the container, which is why they can be stated here
        /// without becoming a second copy of a core policy.
        let jpegIdentifier: Int
        /// What is left when the format can carry the packet and the packet
        /// fits: the writer looked at it and would not vouch for it.
        let refusal: String
    }

    private static let packets: [Packet] = [
        Packet(
            kind: RZ_METADATA_EXIF, bit: RZ_CARRIES_EXIF, label: "EXIF",
            shortName: "EXIF block", indefinite: "an EXIF block", jpegIdentifier: 6,
            refusal: "The EXIF block could not be rewritten safely: its orientation and "
                + "resolution must match this export, and a packet that cannot be "
                + "patched is left out rather than written half-corrected."),
        Packet(
            kind: RZ_METADATA_XMP, bit: RZ_CARRIES_XMP, label: "XMP",
            shortName: "XMP packet", indefinite: "an XMP packet", jpegIdentifier: 29,
            refusal: "The XMP packet was not written."),
        Packet(
            // An 8BIM run is filtered on the way out — the resources that
            // would contradict this export's own density, profile and EXIF
            // are dropped — so a run can also arrive here having filtered
            // down to nothing.
            kind: RZ_METADATA_IPTC, bit: RZ_CARRIES_IPTC, label: "IPTC",
            shortName: "IPTC record", indefinite: "an IPTC record", jpegIdentifier: 14,
            refusal: "The IPTC record is malformed, or held only resources that would "
                + "contradict this export."),
    ]

    /// Largest payload one JPEG marker segment can carry: the 16-bit length
    /// field counts its own two bytes. A packet plus its identifier has to
    /// fit in one, which is the entire reason a 71 KB EXIF block cannot
    /// travel in a JPEG.
    ///
    /// The writer may shrink a packet before it measures it (an 8BIM run
    /// loses the resources that would contradict this export), never grow
    /// it — so a held size that fits with its identifier is proof the drop
    /// was NOT about size, and a size that does not fit is the cause in
    /// every case but a packet that is oversized and malformed at once,
    /// where the sentence names the more useful of the two.
    private static let jpegSegmentPayload = 65533

    // MARK: - Words

    /// The format's name in prose. `displayName` carries the panel popup's
    /// "(lossless)" qualifier, which belongs in a popup and not in a
    /// sentence.
    private static func proseName(_ format: ExportFormat) -> String {
        format == .webp ? "WebP" : format.displayName
    }

    /// "EXIF", "EXIF and XMP", "EXIF, XMP and IPTC" — the house voice, which
    /// is the C header's ("carries no EXIF, XMP or IPTC"), no serial comma.
    /// "nothing" for an empty list, which only a caller asking about a
    /// format that carries no metadata at all can produce.
    private static func list(_ items: [String], conjunction: String = "and") -> String {
        guard let last = items.last else { return "nothing" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " \(conjunction) " + last
    }

    /// A byte count for a sentence. Whole kilobytes up to a megabyte, one
    /// decimal above it: the only sizes this file names are a segment-busting
    /// packet (always tens of KB) and an oversized ICC profile (megabytes),
    /// and neither is helped by more precision.
    private static func byteSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb >= 1024 { return String(format: "%.1f MB", kb / 1024) }
        return "\(max(1, Int(kb.rounded()))) KB"
    }
}
