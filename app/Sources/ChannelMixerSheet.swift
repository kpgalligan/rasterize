import AppKit

/// The Channel Mixer dialog: an Output popup, the three source sliders, a
/// Constant slider and the display-only Total readout, plus Monochrome.
///
/// Every parameter, range and default comes from `AdjustmentSchema`; the
/// lifecycle — the captured handles, the debounced in-context preview, one
/// undo step on Apply and nothing on Cancel — is `AdjustmentSheet`'s, in all
/// three modes (Image ▸ Adjustments, Layer ▸ New Adjustment Layer, and
/// Adjustment Options… on an existing layer).
///
/// The dialog edits FOUR rows and shows one: the popup only chooses which of
/// `red`, `green`, `blue` and `gray` the four sliders write, exactly as
/// Photoshop's does. Monochrome swaps the popup for a single Gray entry (the
/// core then sends the gray row to all three outputs) and leaves the colour
/// rows untouched in the params, so the checkbox is reversible without
/// losing either setting.
///
/// Units follow the core's schema row: a slider runs −200…200 % on screen and
/// −2…2 in the params, quantized to whole percent — Photoshop's own step, and
/// what makes an unchanged re-commit byte-stable, since 40/100 is exactly the
/// 0.4 the schema defaults to. The matrix runs on the ENCODED values (no
/// linearization), and the constant is a fraction too: 0.5 adds 127.5 levels.
final class ChannelMixerSheet: AdjustmentSheet {
    /// The four rows the core parses, and the four keys inside one row.
    /// Both orders are the core's (`adjust_mix::MIXER_ROWS`, `MIXER_KEYS`),
    /// so an index here is the same slot there.
    private static let rowKeys = ["red", "green", "blue", "gray"]
    private static let sourceKeys = ["r", "g", "b", "constant"]
    private static let sourceLabels = ["Red:", "Green:", "Blue:", "Constant:"]

    /// Every row's four values as the core's fractions, read defensively
    /// against the schema's own defaults so a params object that omits a row
    /// — the usual case — opens on exactly the numbers the core would use.
    private lazy var rowValues: [String: [Double]] = {
        var out: [String: [Double]] = [:]
        for key in Self.rowKeys {
            let defaults = AdjustmentSchema.objectDefaults(for: .channelMixer, path: [key])
            let stored = initial.object(key)
            out[key] = Self.sourceKeys.map { source in
                Self.number(stored?[source], defaults[source] as? Double ?? 0)
            }
        }
        return out
    }()

    /// The rows the params the sheet opened on spelled out — see
    /// `currentParams()` for why that is worth remembering.
    private lazy var explicitRows: Set<String> = Set(
        Self.rowKeys.filter { initial.object($0) != nil })

    private lazy var monochrome = initial.bool("monochrome", default: false)

    /// The COLOUR output the popup last showed. Monochrome hides it behind
    /// the Gray row rather than clearing it, so unchecking the box comes back
    /// to the channel the user was on.
    private var output = 0

    private var outputPopup: NSPopUpButton?
    /// The four house rows, kept by their parts: `AdjustmentSheet.sliderRow`
    /// hands back its views and only the row's own action updates the
    /// readout, so switching rows has to set both (the `SliderSheetController`
    /// arrangement).
    private var sliders: [NSSlider] = []
    private var readouts: [NSTextField] = []
    private let totalReadout = NSTextField(labelWithString: "")

    // MARK: - Content

    override func makeContent() -> NSView {
        var rows: [[NSView]] = []
        let outputViews = popupRow(
            "Output:", titles: Self.outputTitles(monochrome: monochrome), selected: 0
        ) { [weak self] index in
            self?.output = index
            self?.showRow()
        }
        outputPopup = outputViews.compactMap { $0 as? NSPopUpButton }.first
        outputPopup?.isEnabled = !monochrome
        rows.append(outputViews)
        rows.append(
            checkboxRow("Monochrome", value: monochrome) { [weak self] on in
                self?.setMonochrome(on)
            })
        // Photoshop's own order: the three source channels, the Total they
        // sum to, then the Constant — which is an offset, not a share of the
        // input, and so is not in the Total.
        for index in 0..<3 { rows.append(track(sourceRow(index))) }
        totalReadout.font = DS.mono(12)
        totalReadout.alignment = .right
        totalReadout.widthAnchor.constraint(equalToConstant: 52).isActive = true
        rows.append([fieldLabel("Total:"), NSGridCell.emptyContentView, totalReadout])
        rows.append(track(sourceRow(3)))

        let note = NSTextField(
            wrappingLabelWithString:
                "Each output channel is a weighted sum of the source channels plus a "
                + "constant. A total above 100 % can clip the output, which is all the "
                + "warning means — the mix is applied exactly as set either way.")
        note.font = DS.sans(12)
        note.textColor = DS.textMuted
        note.preferredMaxLayoutWidth = sheetWidth - sheetInset * 2

        let stack = NSStackView(views: [AdjustmentSheet.grid(rows), note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        updateTotal()
        return stack
    }

    private func sourceRow(_ index: Int) -> [NSView] {
        sliderRow(
            Self.sourceLabels[index], range: -200...200, value: value(index) * 100,
            format: Self.percent
        ) { [weak self] percent in
            self?.setValue(index, percent.rounded() / 100)
        }
    }

    /// Keeps a house row's slider and readout so `showRow()` can retarget
    /// them, and returns the row unchanged for the grid.
    private func track(_ row: [NSView]) -> [NSView] {
        if let slider = row.compactMap({ $0 as? NSSlider }).first { sliders.append(slider) }
        if let readout = row.compactMap({ $0 as? NSTextField }).last { readouts.append(readout) }
        return row
    }

    // MARK: - State

    /// The row the sliders currently write: the gray one under Monochrome,
    /// otherwise whichever colour output the popup names.
    private var currentKey: String {
        monochrome ? "gray" : Self.rowKeys[min(max(output, 0), 2)]
    }

    private func value(_ index: Int) -> Double {
        let values = rowValues[currentKey] ?? []
        return index < values.count ? values[index] : 0
    }

    private func setValue(_ index: Int, _ value: Double) {
        guard var values = rowValues[currentKey], index < values.count else { return }
        values[index] = Self.clamped(value, -2, 2)
        rowValues[currentKey] = values
    }

    private func setMonochrome(_ on: Bool) {
        monochrome = on
        if let popup = outputPopup {
            popup.removeAllItems()
            popup.addItems(withTitles: Self.outputTitles(monochrome: on))
            popup.selectItem(at: on ? 0 : output)
            // With one entry there is nothing to choose: Photoshop replaces
            // the menu with Gray and greys it out.
            popup.isEnabled = !on
        }
        showRow()
    }

    /// Reloads the four sliders from the row the popup now names. AppKit
    /// sends no action for a programmatic value change, so the readouts are
    /// set here too — and the caller's own `valuesChanged()` is the one
    /// preview the whole switch needs.
    private func showRow() {
        for index in 0..<min(sliders.count, readouts.count) {
            let percent = value(index) * 100
            sliders[index].doubleValue = percent
            readouts[index].stringValue = Self.percent(percent)
        }
        updateTotal()
    }

    /// Photoshop's Total: the three SOURCE weights summed and shown signed.
    /// Above 100 % the output can clip, which is the only thing the warning
    /// colour says — rows may sum to anything, and nothing here clamps them.
    /// The colour is the amber the histogram's clipping wedge already uses
    /// (`HistogramView`); `DS` has no warning token, and inventing one for a
    /// single readout would be a worse kind of drift.
    private func updateTotal() {
        let values = rowValues[currentKey] ?? []
        let total = (values.prefix(3).reduce(0, +) * 100).rounded()
        totalReadout.stringValue = String(format: "%+.0f %%", total)
        totalReadout.textColor = total > 100 ? .systemOrange : DS.textMuted
    }

    override func valuesChanged() {
        updateTotal()
        super.valuesChanged()
    }

    // MARK: - Params

    /// One rule for every key here: **write it when its value differs from
    /// the core's default for it, or when the params the sheet opened on
    /// already carried it.** The core reads an absent key (a whole absent
    /// row included) as exactly those defaults, so the pixels are the same
    /// either way; what the rule buys is a small meta — it travels in `.rz`
    /// and in every `get_document` reply — and a byte-identical re-commit
    /// when nothing was touched.
    override func currentParams() -> [String: Any] {
        var params: [String: Any] = [:]
        if monochrome || initial.params["monochrome"] != nil {
            params["monochrome"] = monochrome
        }
        for key in Self.rowKeys {
            guard let values = rowValues[key], values.count == Self.sourceKeys.count else {
                continue
            }
            let defaults = AdjustmentSchema.objectDefaults(for: .channelMixer, path: [key])
            let isDefault = zip(Self.sourceKeys, values).allSatisfy { source, value in
                value == (defaults[source] as? Double ?? 0)
            }
            guard !isDefault || explicitRows.contains(key) else { continue }
            params[key] = Dictionary(uniqueKeysWithValues: zip(Self.sourceKeys, values))
        }
        return params
    }

    override var footnote: String { "total is advisory · one undo step" }

    // MARK: - Helpers

    private static func outputTitles(monochrome: Bool) -> [String] {
        monochrome ? ["Gray"] : rowKeys.prefix(3).map { $0.capitalized }
    }

    /// Photoshop's own readout: whole percent, the step the sliders quantize
    /// to.
    private static func percent(_ value: Double) -> String {
        String(format: "%.0f %%", value.rounded())
    }

    /// One nested value, defensively — missing, non-numeric and non-finite
    /// all read as `fallback`, the contract `AdjustmentLayerPayload.number`
    /// has for a top-level key — clamped into the schema's ±2.
    private static func number(_ value: Any?, _ fallback: Double) -> Double {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else {
            return fallback
        }
        return clamped(number, -2, 2)
    }

    private static func clamped(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
