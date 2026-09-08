import AppKit
import UniformTypeIdentifiers

/// The Color Lookup dialog: a Load .cube… button, the parsed table's title and size, and a Strength slider.
///
/// Every parameter, range and default comes from `AdjustmentSchema`; the
/// lifecycle — the captured handles, the debounced in-context preview, one
/// undo step on Apply and nothing on Cancel — is `AdjustmentSheet`'s, in all
/// three modes (Image ▸ Adjustments, Layer ▸ New Adjustment Layer, and
/// Adjustment Options… on an existing layer).
///
/// **The table is the core's, byte for byte.** `RasterLUT.parseCube` returns
/// the params object the layer stores — kind, size, source_size, the domain
/// corners, the base64 table and any title — and this sheet passes it
/// through untouched, adding only the Strength slider's value. It never
/// decodes or re-encodes a loaded table: the one table this side ever builds
/// is the two-node identity a fresh layer starts on (`identityTable`).
///
/// **`source_size` is what the .cube itself declared.** This build stores 3D
/// tables up to 33³ and 1D up to 1024, and the core resamples a larger file
/// down, so a 64³ LUT arrives as `size` 33 with `source_size` 64 and the
/// info line says "resampled from 64³". It is a real schema key, accepted by
/// the core and by `AdjustmentSchema`, so it survives every
/// `edit_adjustment_layer` round trip rather than being lost on the first
/// re-commit.
final class ColorLookupSheet: AdjustmentSheet {
    /// Everything but `strength`: the params the loaded (or identity) table
    /// contributes, kept exactly as the core spelled them.
    private var table: [String: Any] = [:]
    private var strength = 1.0
    /// False while `table` is the built-in identity — the sheet says so
    /// rather than describing a LUT nobody chose.
    private var loaded = false
    private var didBuildControls = false
    private let infoLabel = NSTextField(wrappingLabelWithString: "")

    override var footnote: String { "table lives in the layer · 1 undo" }

    // MARK: - Controls

    override func makeContent() -> NSView {
        if let stored = Self.storedTable(from: initial) {
            table = stored
            loaded = true
        } else {
            table = Self.identityTable()
            loaded = false
        }
        strength = min(max(initial.number("strength", default: 1), 0), 1)

        let loadButton = StickerButton(
            title: "Load .cube…", style: .secondary, target: self,
            action: #selector(loadClicked(_:)))
        infoLabel.font = DS.mono(11)
        infoLabel.textColor = DS.textMuted
        infoLabel.preferredMaxLayoutWidth = sheetWidth - sheetInset * 2
        updateInfo()

        let grid = Self.grid([
            sliderRow(
                "Strength:", range: 0...1, value: strength,
                format: { String(format: "%.0f %%", $0 * 100) }
            ) { [weak self] value in
                self?.strength = value
            }
        ])
        let content = NSStackView(views: [loadButton, infoLabel, grid])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        didBuildControls = true
        return content
    }

    override func currentParams() -> [String: Any] {
        // The lifecycle always builds the controls first (loadView runs
        // before viewDidAppear and before Apply); answering with the params
        // the sheet opened on is the honest fallback if that ever changes.
        guard didBuildControls else { return initial.params }
        var out = table
        out["strength"] = strength
        return out
    }

    // MARK: - Loading a .cube

    @objc private func loadClicked(_ sender: Any?) {
        guard let window = view.window else {
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an Adobe Cube LUT (.cube)."
        panel.prompt = "Load"
        // Nothing registers the extension, so this is a dynamic type; it
        // still filters by extension, which is all the panel needs. Left
        // unset if even that fails, rather than showing an empty panel.
        if let type = UTType(filenameExtension: "cube") {
            panel.allowedContentTypes = [type]
        }
        // A sheet on the dialog's own window: the panel belongs to this
        // dialog, not to the document behind it.
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }

    /// Parses the file through the core and takes its params whole.
    ///
    /// Synchronous on the main thread, deliberately: it is a file the user
    /// just picked, a 33³ table is ~575 KB of text and the core refuses a
    /// file over its 64 MiB read cap before reading a byte of it. A refusal
    /// is shown with the core's OWN message, which names the path and what
    /// was wrong.
    private func load(_ url: URL) {
        switch RasterLUT.parseCube(path: url.path) {
        case .success(let params):
            // This is the ONE sheet whose params come from a file instead of
            // from schema-clamped controls, so it is the one sheet that has
            // to ask the schema — the same gate `add_adjustment_layer` puts
            // on the agent's `file` key. Skipping it meant a table the
            // compositor's own parser refuses could be committed, and the
            // user would be left with a layer that composites as plain
            // raster and can only be deleted. An alert here is the
            // difference between a refusal and wreckage.
            do {
                table = try AdjustmentSchema.validate(params, for: .colorLookup)
            } catch {
                presentLUTAlert(
                    (error as? AgentServer.ToolError)?.message
                        ?? "That LUT is not one this build can store.")
                return
            }
            loaded = true
            updateInfo()
            valuesChanged()
        case .failure(let error):
            presentLUTAlert(error.message)
        }
    }

    private func presentLUTAlert(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Cannot Read That LUT"
        alert.informativeText = reason
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - What is loaded

    private func updateInfo() {
        infoLabel.stringValue = infoText()
    }

    private func infoText() -> String {
        guard loaded else {
            return "No LUT loaded — Color Lookup passes every colour through unchanged "
                + "until a .cube is chosen."
        }
        let threeD = (table["kind"] as? String) == "3d"
        let size = (table["size"] as? NSNumber)?.intValue ?? 0
        let source = (table["source_size"] as? NSNumber)?.intValue ?? size
        var parts: [String] = []
        if let title = table["title"] as? String, !title.isEmpty { parts.append(title) }
        parts.append(threeD ? "3D \(size)×\(size)×\(size)" : "1D \(size) nodes")
        // The one thing source_size exists to say: the file was bigger than
        // this build stores, and the core resampled it down.
        if source > size { parts.append("resampled from \(source)" + (threeD ? "³" : "")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tables

    /// The layer's own table, or nil when its params carry no complete one —
    /// which is what a freshly created layer's do, since `kind`, `size` and
    /// `table` are required and have no defaults.
    ///
    /// Every key but `strength` is passed through EXACTLY as stored, absent
    /// keys included, so re-committing an untouched layer produces the
    /// identical meta and therefore no undo step.
    private static func storedTable(from payload: AdjustmentLayerPayload) -> [String: Any]? {
        let kind = payload.string("kind", default: "")
        let size = (payload.params["size"] as? NSNumber)?.intValue ?? 0
        guard kind == "1d" || kind == "3d", size >= 2, payload.params["table"] is String
        else { return nil }
        var out = payload.params
        out.removeValue(forKey: "strength")
        return out
    }

    /// The identity a Color Lookup layer starts on: a 1D table of two nodes,
    /// black to white, which every channel passes through unchanged.
    ///
    /// It exists because an adjustment layer must carry a COMPLETE table to
    /// be an adjustment layer at all — the core reads a `color_lookup`
    /// params object with no table as unparseable, and such a layer degrades
    /// to an empty raster one — so the sheet always has something valid to
    /// preview and commit, and until a .cube is loaded that something does
    /// nothing. The domain corners are left out: the core's own defaults are
    /// [0,0,0] and [1,1,1], and a shorter meta travels in `.rz` and in every
    /// `get_document` reply.
    private static func identityTable() -> [String: Any] {
        ["kind": "1d", "size": 2, "table": encoded([0, 0, 0, 1, 1, 1])]
    }

    /// Little-endian f32 as the base64 the schema stores. The ONLY table
    /// this side ever builds — a loaded one comes back from
    /// `RasterLUT.parseCube` already encoded and is never touched.
    private static func encoded(_ values: [Float]) -> String {
        var bytes = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes.base64EncodedString()
    }
}
