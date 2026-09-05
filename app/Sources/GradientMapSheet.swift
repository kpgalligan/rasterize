import AppKit

/// The Gradient Map dialog: the reusable GradientEditorView, a stop position and opacity field, Reverse and Dither.
///
/// Every parameter, range and default comes from `AdjustmentSchema`; the
/// lifecycle — the captured handles, the debounced in-context preview, one
/// undo step on Apply and nothing on Cancel — is `AdjustmentSheet`'s, in all
/// three modes (Image ▸ Adjustments, Layer ▸ New Adjustment Layer, and
/// Adjustment Options… on an existing layer).
///
/// The op maps each pixel's Rec. 709 luma through the ramp, and a stop's
/// opacity blends back toward the pixel's ORIGINAL colour — an adjustment
/// may not touch alpha, so that is the only meaning transparency can have
/// here, and it is Photoshop's too.
///
/// **The stop colours are this document's own numbers**, not authored sRGB:
/// an adjustment is a function of the pixels it transforms, so its colours
/// live in their space and convert nowhere. The editor is handed
/// `documentColorSpace` for exactly that reason, and the named presets below
/// — which really are sRGB colours — convert ONCE, at the moment they are
/// picked, through `AdjustmentColor.documentHex(forSRGBHex:in:)`.
final class GradientMapSheet: AdjustmentSheet, NSTextFieldDelegate {
    /// The preset ramps, in popup order. "Custom" is index 0 and picking it
    /// changes nothing: it is what the popup shows whenever the ramp matches
    /// no preset, which is the moment the user edits a stop.
    private static let presetTitles = [
        "Custom", "Black → White", "White → Black", "Paint → Background",
    ]

    private let editor = GradientEditorView(frame: NSRect(x: 0, y: 0, width: 376, height: 62))
    private let positionField = NSTextField(string: "")
    private let opacityField = NSTextField(string: "")
    private weak var presetPopup: NSPopUpButton?
    private weak var colorWell: NSColorWell?
    private var dither = true
    /// Set once `makeContent()` has run. `currentParams()` can then read the
    /// controls; before that the sheet has nothing but what it opened on.
    private var didBuildControls = false
    /// True while the controls are being refilled FROM the model, so the
    /// writes that refill triggers (an `NSColorWell` sends its action when
    /// its colour is set) are not read back as user edits.
    private var isSyncing = false

    /// The colour rule, at the surface that carries a swatch: what a
    /// stop stores is the DOCUMENT's numbers, not an authored sRGB colour.
    override var footnote: String { "document-space colours · 1 undo" }

    // MARK: - Controls

    override func makeContent() -> NSView {
        editor.colorSpace = documentColorSpace
        editor.fill = Self.fill(from: initial)
        editor.selectedStop = 0
        editor.onFillChanged = { [weak self] _ in self?.editorChanged() }
        editor.onSelectionChanged = { [weak self] _ in self?.stopSelectionChanged() }
        editor.onEditColor = { [weak self] _ in self?.editStopColor() }
        editor.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editor.widthAnchor.constraint(equalToConstant: sheetWidth - sheetInset * 2),
            editor.heightAnchor.constraint(equalToConstant: 62),
        ])
        dither = initial.bool("dither", default: true)

        for field in [positionField, opacityField] { styleField(field) }

        let presetRow = popupRow(
            "Preset:", titles: Self.presetTitles, selected: presetIndex()
        ) { [weak self] index in
            self?.applyPreset(index)
        }
        presetPopup = presetRow.compactMap { $0 as? NSPopUpButton }.first
        let colorViews = colorRow("Color:", hex: selectedStop()?.color ?? "#000000") {
            [weak self] hex in
            self?.colorPicked(hex)
        }
        colorWell = colorViews.compactMap { $0 as? NSColorWell }.first

        let rows: [[NSView]] = [
            presetRow,
            [NSGridCell.emptyContentView, microHeader("Selected stop")],
            [fieldLabel("Position:"), percentRow(positionField)],
            [fieldLabel("Opacity:"), percentRow(opacityField)],
            colorViews,
            checkboxRow("Reverse", value: editor.fill.reverse) { [weak self] on in
                self?.setReverse(on)
            },
            // On by default: an 8-bit map over a smooth sky bands visibly
            // without it, and the offset is a deterministic sub-level nudge
            // (the Dissolve blend mode's own threshold), not noise.
            checkboxRow("Dither", value: dither) { [weak self] on in
                self?.dither = on
            },
        ]
        let content = NSStackView(views: [editor, Self.grid(rows)])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        didBuildControls = true
        syncStopControls()
        return content
    }

    override func currentParams() -> [String: Any] {
        // The lifecycle always builds the controls first (loadView runs
        // before viewDidAppear and before Apply); answering with the params
        // the sheet opened on is the honest fallback if that ever changes.
        guard didBuildControls else { return initial.params }
        return ["gradient": editor.fill.mapParams, "dither": dither]
    }

    // MARK: - Editing

    private func editorChanged() {
        syncStopControls()
        updatePresetSelection()
        valuesChanged()
    }

    private func stopSelectionChanged() {
        syncStopControls()
    }

    /// A double-click on a stop opens the colour panel — by activating the
    /// sheet's own well, which is already bound to this document's space, so
    /// the panel is driven by AppKit rather than by a second hand-rolled
    /// target on a shared window.
    private func editStopColor() {
        colorWell?.activate(true)
    }

    private func colorPicked(_ hex: String) {
        guard !isSyncing else { return }
        editor.setColor(hex, forStop: editor.selectedStop)
        updatePresetSelection()
    }

    /// The two fields edit live, as `ImageSizeSheetController`'s do: every
    /// keystroke moves the stop and re-previews, and the field being typed
    /// in is never rewritten underneath the caret (`except:`). An empty
    /// field is a keystroke on the way to a number, not a request to put
    /// the stop at zero.
    func controlTextDidChange(_ obj: Notification) {
        guard !isSyncing, let field = obj.object as? NSTextField,
              !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty,
              selectedStop() != nil
        else { return }
        let index = editor.selectedStop
        let percent = min(max(field.doubleValue, 0), 100)
        if field === positionField {
            editor.setPosition(percent / 100, forStop: index)
        } else if field === opacityField {
            editor.setOpacity(percent / 100, forStop: index)
        } else {
            return
        }
        syncStopControls(except: field)
        updatePresetSelection()
        valuesChanged()
    }

    /// Reformats both fields once the caret leaves — a dragged stop's
    /// position is a fraction of a percent, and this is where the field
    /// stops showing what was typed and starts showing what is stored.
    func controlTextDidEndEditing(_ obj: Notification) {
        syncStopControls()
    }

    private func setReverse(_ on: Bool) {
        var fill = editor.fill
        fill.reverse = on
        editor.fill = fill
    }

    /// Replaces the ramp with a preset's stops, keeping Reverse as the user
    /// left it (it is its own control, and a preset should not reach across
    /// and flip it). Index 0 is "Custom" and changes nothing.
    private func applyPreset(_ index: Int) {
        guard let stops = Self.presetStops(index, in: documentColorSpace) else { return }
        var fill = editor.fill
        fill.stops = stops
        editor.fill = fill
        editor.selectedStop = 0
        syncStopControls()
    }

    // MARK: - Keeping the controls and the ramp in step

    private func selectedStop() -> GradientStop? {
        let stops = editor.fill.stops
        let index = editor.selectedStop
        return stops.indices.contains(index) ? stops[index] : nil
    }

    /// Refills the per-stop controls from the ramp. `except` is the field
    /// the user is typing in, which must keep its own text (and its caret).
    private func syncStopControls(except editing: NSTextField? = nil) {
        guard didBuildControls else { return }
        isSyncing = true
        defer { isSyncing = false }
        guard let stop = selectedStop() else {
            for field in [positionField, opacityField] {
                field.stringValue = ""
                field.isEnabled = false
            }
            colorWell?.isEnabled = false
            return
        }
        for field in [positionField, opacityField] { field.isEnabled = true }
        colorWell?.isEnabled = true
        // Written through the field's own formatter, so the decimal
        // separator is the user's and what is shown parses back.
        if positionField !== editing { positionField.doubleValue = stop.position * 100 }
        if opacityField !== editing { opacityField.doubleValue = stop.opacity * 100 }
        colorWell?.color =
            AdjustmentColor.color(fromHex: stop.color, in: documentColorSpace) ?? .black
    }

    /// The preset the ramp currently spells, or 0 ("Custom"). Compared on
    /// the CONVERTED colours, so a preset stays recognized on a document
    /// whose numbers are not sRGB's.
    private func presetIndex() -> Int {
        let stops = editor.fill.stops
        for index in 1..<Self.presetTitles.count
        where Self.presetStops(index, in: documentColorSpace) == stops {
            return index
        }
        return 0
    }

    private func updatePresetSelection() {
        presetPopup?.selectItem(at: presetIndex())
    }

    // MARK: - Layout pieces

    private func microHeader(_ title: String) -> NSTextField {
        NSTextField(labelWithAttributedString: DS.microLabel(title))
    }

    /// A percentage field in the house style: 0…100 with one decimal, which
    /// is as fine as the ~376 pt ramp resolves (a point is about a quarter
    /// of a percent).
    private func styleField(_ field: NSTextField) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = true
        formatter.maximumFractionDigits = 1
        formatter.minimum = 0
        formatter.maximum = 100
        field.formatter = formatter
        field.delegate = self
        field.alignment = .right
        DSField.style(field)
        field.widthAnchor.constraint(equalToConstant: 62).isActive = true
    }

    private func percentRow(_ field: NSTextField) -> NSView {
        let suffix = NSTextField(labelWithString: "%")
        suffix.font = DS.sans(13)
        suffix.textColor = DS.textMuted
        let row = NSStackView(views: [field, suffix])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    // MARK: - Presets and params

    /// A preset's stops in the DOCUMENT's numbers. The tables are sRGB —
    /// `#000000` and `#ffffff` are sRGB spellings, and the paint colours are
    /// stored as sRGB by `TextLayer.hex` — so each converts ONCE here, at
    /// the moment it is picked, and what gets stored is the document's own
    /// spelling like every other adjustment colour. nil for "Custom".
    private static func presetStops(_ index: Int, in space: NSColorSpace) -> [GradientStop]? {
        let shared = ToolOptionsStore.shared.sharedState
        let pair: (String, String)
        switch index {
        case 1: pair = ("#000000", "#ffffff")
        case 2: pair = ("#ffffff", "#000000")
        // The paint pair is spelled "#RRGGBBAA"; the alpha is dropped, since
        // a stop's own opacity means something else here (how much of the
        // original colour survives) and the paint swatch's does not.
        case 3: pair = (shared.foreground, shared.background)
        default: return nil
        }
        return [
            GradientStop(
                position: 0, color: AdjustmentColor.documentHex(forSRGBHex: pair.0, in: space),
                opacity: 1),
            GradientStop(
                position: 1, color: AdjustmentColor.documentHex(forSRGBHex: pair.1, in: space),
                opacity: 1),
        ]
    }

    /// The ramp a Gradient Map's params describe, defensively: a missing or
    /// malformed `gradient`, or one with fewer than two stops, falls back to
    /// the schema's black→white default rather than refusing to open — the
    /// contract every `AdjustmentLayerPayload` reader keeps.
    private static func fill(from payload: AdjustmentLayerPayload) -> GradientFill {
        var out = GradientFill()
        guard let object = payload.object("gradient") else { return out }
        if let reverse = object["reverse"] as? NSNumber { out.reverse = reverse.boolValue }
        guard let list = object["stops"] as? [Any] else { return out }
        var stops: [GradientStop] = []
        for entry in list {
            guard let stop = entry as? [String: Any] else { continue }
            let position = (stop["position"] as? NSNumber)?.doubleValue ?? 0
            let opacity = (stop["opacity"] as? NSNumber)?.doubleValue ?? 1
            stops.append(
                GradientStop(
                    position: position.isFinite ? min(max(position, 0), 1) : 0,
                    color: normalizedHex(stop["color"]),
                    opacity: opacity.isFinite ? min(max(opacity, 0), 1) : 1))
        }
        if stops.count >= GradientEditorView.minStops { out.stops = stops }
        return out
    }

    /// A stored `"#rrggbb"`, or black for anything that is not six hex
    /// digits behind a `#` — the spelling check `AdjustmentLayerPayload`
    /// does, and nothing more: an adjustment's colour converts nowhere.
    private static func normalizedHex(_ value: Any?) -> String {
        guard let text = value as? String, text.count == 7, text.hasPrefix("#"),
              text.dropFirst().allSatisfy({ $0.isHexDigit })
        else { return "#000000" }
        return text.lowercased()
    }
}

extension GradientFill {
    /// The `gradient` object a `gradient_map`'s params carry: `stops` and
    /// `reverse`, and nothing else.
    ///
    /// The core takes the SAME object a layer style's gradient is written
    /// as, through the same parser — but a map has no geometry, so `style`,
    /// `angle`, `scale` and `align_with_layer` are accepted and ignored, and
    /// `AdjustmentSchema.defaultGradient` writes these two keys as well.
    /// Writing the rest would lengthen a meta that travels in `.rz` and in
    /// every `get_document` reply, and would make re-committing an unchanged
    /// gradient a fresh undo step — the sheet would spell the same picture
    /// differently from the way it read it.
    var mapParams: [String: Any] {
        [
            "stops": stops.map {
                ["position": $0.position, "color": $0.color, "opacity": $0.opacity]
            },
            "reverse": reverse,
        ]
    }
}
