import AppKit

/// The Selective Color dialog: a nine-range Colors popup, the four ink
/// sliders and the Relative/Absolute method pair.
///
/// Every parameter, range and default comes from `AdjustmentSchema`; the
/// lifecycle — the captured handles, the debounced in-context preview, one
/// undo step on Apply and nothing on Cancel — is `AdjustmentSheet`'s, in all
/// three modes (Image ▸ Adjustments, Layer ▸ New Adjustment Layer, and
/// Adjustment Options… on an existing layer).
///
/// The dialog edits NINE ranges and shows one: the popup only chooses which
/// `{c, m, y, k}` block the four sliders write, exactly as Photoshop's does.
/// A slider runs ±100 % on screen and ±1 in the params, quantized to whole
/// percent — Photoshop's own step, and what makes an unchanged re-commit
/// byte-stable, since 10/100 is exactly the 0.1 a re-read would produce.
///
/// The two methods are the ones Adobe documents, and the core implements
/// them verbatim (`adjust_mix`): on 50 % magenta with magenta +10 %,
/// Relative scales the ink already there (→ 55 %) while Absolute adds the
/// amount outright (→ 60 %). The ranges overlap by design — a pale red pixel
/// is in Reds *and* in Neutrals, and both nudges apply.
final class SelectiveColorSheet: AdjustmentSheet {
    /// The four ink keys the core parses, in its own order (`INK_KEYS` in
    /// `adjust_mix`), and the CMYK names Photoshop's dialog shows for them.
    private static let inkKeys = ["c", "m", "y", "k"]
    private static let inkLabels = ["Cyan:", "Magenta:", "Yellow:", "Black:"]

    /// Every range's four nudges as the core's fractions. All nine default to
    /// zero, so a params object that omits a range — the usual case, since
    /// this sheet omits the ones nobody touched — opens on exactly the
    /// numbers the core would use.
    private lazy var rangeValues: [String: [Double]] = {
        var out: [String: [Double]] = [:]
        for key in AdjustmentSchema.selectiveRanges {
            let stored = initial.object(key)
            out[key] = Self.inkKeys.map { Self.number(stored?[$0]) }
        }
        return out
    }()

    /// The ranges the params the sheet opened on spelled out — see
    /// `currentParams()` for why that is worth remembering.
    private lazy var explicitRanges: Set<String> = Set(
        AdjustmentSchema.selectiveRanges.filter { initial.object($0) != nil })

    private lazy var absolute = initial.string("method", default: "relative") == "absolute"

    /// The range the four sliders currently write, as an index into
    /// `AdjustmentSchema.selectiveRanges`.
    private var selected = 0

    /// The four house rows, kept by their parts: `AdjustmentSheet.sliderRow`
    /// hands back its views and only the row's own action updates the
    /// readout, so switching ranges has to set both (the
    /// `SliderSheetController` arrangement).
    private var sliders: [NSSlider] = []
    private var readouts: [NSTextField] = []
    private var methodButtons: [NSButton] = []

    // MARK: - Content

    override func makeContent() -> NSView {
        // The popup titles ARE the schema keys capitalized, so the dialog and
        // the params can never name different ranges.
        var rows: [[NSView]] = [
            popupRow(
                "Colors:", titles: AdjustmentSchema.selectiveRanges.map { $0.capitalized },
                selected: selected
            ) { [weak self] index in
                self?.selected = index
                self?.showRange()
            }
        ]
        for index in 0..<Self.inkKeys.count {
            rows.append(
                track(
                    sliderRow(
                        Self.inkLabels[index], range: -100...100, value: value(index) * 100,
                        format: Self.percent
                    ) { [weak self] percent in
                        self?.setValue(index, percent.rounded() / 100)
                    }))
        }
        rows.append(makeMethodRow())

        let note = NSTextField(
            wrappingLabelWithString:
                "Relative scales the ink a pixel already has; Absolute adds the amount "
                + "outright. The ranges overlap — a pale red pixel is in Reds and in "
                + "Neutrals, and both nudges reach it.")
        note.font = DS.sans(12)
        note.textColor = DS.textMuted
        note.preferredMaxLayoutWidth = sheetWidth - sheetInset * 2

        let stack = NSStackView(views: [AdjustmentSheet.grid(rows), note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func makeMethodRow() -> [NSView] {
        let relative = NSButton(
            radioButtonWithTitle: "Relative", target: self, action: #selector(methodChanged(_:)))
        relative.tag = 0
        let absoluteButton = NSButton(
            radioButtonWithTitle: "Absolute", target: self, action: #selector(methodChanged(_:)))
        absoluteButton.tag = 1
        methodButtons = [relative, absoluteButton]
        for button in methodButtons { button.font = DS.sans(13) }
        syncMethod()
        let stack = NSStackView(views: methodButtons)
        stack.orientation = .horizontal
        stack.spacing = 12
        return [fieldLabel("Method:"), stack]
    }

    /// Keeps a house row's slider and readout so `showRange()` can retarget
    /// them, and returns the row unchanged for the grid.
    private func track(_ row: [NSView]) -> [NSView] {
        if let slider = row.compactMap({ $0 as? NSSlider }).first { sliders.append(slider) }
        if let readout = row.compactMap({ $0 as? NSTextField }).last { readouts.append(readout) }
        return row
    }

    // MARK: - State

    private var currentKey: String {
        let ranges = AdjustmentSchema.selectiveRanges
        return ranges[min(max(selected, 0), ranges.count - 1)]
    }

    private func value(_ index: Int) -> Double {
        let values = rangeValues[currentKey] ?? []
        return index < values.count ? values[index] : 0
    }

    private func setValue(_ index: Int, _ value: Double) {
        guard var values = rangeValues[currentKey], index < values.count else { return }
        values[index] = Self.clamped(value)
        rangeValues[currentKey] = values
    }

    /// Reloads the four sliders from the range the popup now names. AppKit
    /// sends no action for a programmatic value change, so the readouts are
    /// set here too — and the popup row's own `valuesChanged()` is the one
    /// preview the whole switch needs.
    private func showRange() {
        for index in 0..<min(sliders.count, readouts.count) {
            let percent = value(index) * 100
            sliders[index].doubleValue = percent
            readouts[index].stringValue = Self.percent(percent)
        }
    }

    @objc private func methodChanged(_ sender: Any?) {
        guard let button = sender as? NSButton else { return }
        absolute = button.tag == 1
        syncMethod()
        valuesChanged()
    }

    /// The pair carries its own exclusivity. AppKit auto-groups radio buttons
    /// that share a superview and an action, but the initial state comes from
    /// the LAYER, not from a click, so both states are set here — in the one
    /// place, from the one value the params are built from.
    private func syncMethod() {
        for button in methodButtons {
            button.state = (button.tag == 1) == absolute ? .on : .off
        }
    }

    // MARK: - Params

    /// One rule for every key here: **write it when its value differs from
    /// the core's default for it, or when the params the sheet opened on
    /// already carried it.** An all-zero range is exactly what the core reads
    /// from an ABSENT one, so leaving the eight ranges nobody touched out
    /// changes no pixel; what it buys is a small meta — it travels in `.rz`
    /// and in every `get_document` reply, and nine spelled-out blocks would
    /// be most of it — and a byte-identical re-commit when nothing was
    /// touched.
    override func currentParams() -> [String: Any] {
        var params: [String: Any] = [:]
        if absolute || initial.params["method"] != nil {
            params["method"] = absolute ? "absolute" : "relative"
        }
        for key in AdjustmentSchema.selectiveRanges {
            guard let values = rangeValues[key], values.count == Self.inkKeys.count else {
                continue
            }
            guard values.contains(where: { $0 != 0 }) || explicitRanges.contains(key) else {
                continue
            }
            params[key] = Dictionary(uniqueKeysWithValues: zip(Self.inkKeys, values))
        }
        return params
    }

    override var footnote: String { "±100 % ink per range · 1 undo" }

    // MARK: - Helpers

    /// Photoshop's own readout: whole percent, the step the sliders quantize
    /// to.
    private static func percent(_ value: Double) -> String {
        String(format: "%.0f %%", value.rounded())
    }

    /// One nested value, defensively — missing, non-numeric and non-finite
    /// all read as 0, the contract `AdjustmentLayerPayload.number` has for a
    /// top-level key — clamped into the schema's ±1.
    private static func number(_ value: Any?) -> Double {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return 0 }
        return clamped(number)
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }
}
