import AppKit

/// The Color Balance dialog: a Tone popup (Shadows, Midtones, Highlights)
/// over the three opposed-colour sliders every version of this dialog has
/// had, plus Preserve Luminosity.
///
/// One params object throughout — the popup only chooses which of the three
/// `{cyan_red, magenta_green, yellow_blue}` blocks the sliders write into —
/// and a tone whose three values are all zero is left out of the meta: the
/// core reads an absent block as exactly that block's defaults, so dropping
/// it is the same picture and a shorter `.rz`.
///
/// Every parameter, range and default comes from `AdjustmentSchema`; the
/// lifecycle — the captured handles, the debounced in-context preview, one
/// undo step on Apply and nothing on Cancel — is `AdjustmentSheet`'s, in all
/// three modes (Image ▸ Adjustments, Layer ▸ New Adjustment Layer, and
/// Adjustment Options… on an existing layer).
final class ColorBalanceSheet: AdjustmentSheet {
    /// The meta's three tone blocks, in the order the popup lists them.
    private static let toneKeys = ["shadows", "midtones", "highlights"]
    private static let toneTitles = ["Shadows", "Midtones", "Highlights"]
    /// The meta's three axes, and the opposed pairs Photoshop labels them
    /// with: pushing one slider toward Red is pushing it away from Cyan.
    private static let axisKeys = ["cyan_red", "magenta_green", "yellow_blue"]
    private static let axisLabels = ["Cyan / Red:", "Magenta / Green:", "Yellow / Blue:"]

    /// [tone][axis], unit floats as the meta stores them.
    private var tones: [[Double]] = []
    private var preserveLuminosity = true
    /// Midtones, which is where Photoshop's dialog opens and where a colour
    /// cast is usually corrected.
    private var tone = 1
    /// The retuners for the three sliders the popup re-points, in axis
    /// order. Assigned in `makeContent`.
    private var showAxis: [(Double) -> Void] = []

    override init(
        op: AdjustmentLayerOp, document: ImageDocument, canvas: ImageCanvasView,
        mode: AdjustmentSheetMode
    ) {
        super.init(op: op, document: document, canvas: canvas, mode: mode)
        // A block the params omit is the schema's defaults, so the two are
        // merged before reading: what the layer says wins, and what it
        // leaves out comes back as the factory zero rather than as nothing.
        for key in Self.toneKeys {
            var merged = AdjustmentSchema.objectDefaults(for: op, path: [key])
            if let stored = initial.object(key) {
                merged.merge(stored) { _, new in new }
            }
            let block = AdjustmentLayerPayload(op: op, params: merged)
            tones.append(Self.axisKeys.map { clamped(block.number($0, default: 0), -1...1) })
        }
        preserveLuminosity = initial.bool("preserve_luminosity", default: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColorBalanceSheet does not support NSCoder")
    }

    override func makeContent() -> NSView {
        let toneRow = popupRow("Tone:", titles: Self.toneTitles, selected: tone) {
            [weak self] index in self?.selectTone(index)
        }
        var axisRows: [[NSView]] = []
        showAxis = []
        for (axis, label) in Self.axisLabels.enumerated() {
            let row = sliderRow(
                label, range: -100...100, value: value(axis) * 100, format: percentText
            ) { [weak self] value in self?.setAxis(axis, value.rounded() / 100) }
            axisRows.append(row)
            showAxis.append(retuner(row, percentText))
        }
        let preserveRow = checkboxRow(
            "Preserve Luminosity", value: preserveLuminosity
        ) { [weak self] on in self?.preserveLuminosity = on }
        return AdjustmentSheet.grid([toneRow] + axisRows + [preserveRow])
    }

    override func currentParams() -> [String: Any] {
        var params: [String: Any] = ["preserve_luminosity": preserveLuminosity]
        for (index, key) in Self.toneKeys.enumerated() {
            guard tones.indices.contains(index) else { continue }
            let values = tones[index]
            // A tone that moves nothing is left out entirely: the core
            // reads an absent block as its defaults, so this is the same
            // picture in a shorter meta.
            guard values.contains(where: { $0 != 0 }) else { continue }
            var block: [String: Any] = [:]
            for (axis, name) in Self.axisKeys.enumerated() { block[name] = values[axis] }
            params[key] = block
        }
        return params
    }

    /// The one thing the checkbox's name does not say: it holds the pixel's
    /// Rec. 709 LUMA, by rescaling the balanced colour back to the luma it
    /// started with — not by substituting an HSL lightness, which is the
    /// other reading of "preserve luminosity" and darkens a midtone by
    /// about twelve levels.
    override var footnote: String { "Preserve holds Rec. 709 luma" }

    // MARK: - The selected tone

    private func value(_ axis: Int) -> Double {
        guard tones.indices.contains(tone), tones[tone].indices.contains(axis) else { return 0 }
        return tones[tone][axis]
    }

    private func setAxis(_ axis: Int, _ value: Double) {
        guard tones.indices.contains(tone), tones[tone].indices.contains(axis) else { return }
        tones[tone][axis] = value
    }

    private func selectTone(_ index: Int) {
        tone = min(max(index, 0), Self.toneKeys.count - 1)
        for (axis, show) in showAxis.enumerated() { show(value(axis) * 100) }
    }
}

/// Photoshop's ±100 readout for a slider whose stored value is that over
/// 100 (the phase's numeric convention). Whole numbers only, because what
/// the row writes is `rounded() / 100`.
private let percentText: (Double) -> String = { String(format: "%.0f%%", $0) }

/// A setter that shows a value in the house slider row it was built from.
/// `AdjustmentSheet.sliderRow` returns the row as `[label, slider,
/// readout]` and hands back no handles, and this dialog retunes the SAME
/// three sliders when the tone popup moves rather than building a set per
/// tone — so it takes the two controls back out of the array. Setting the
/// slider's value fires no action, which is what the caller wants: it
/// retunes all three rows and previews once at the end.
private func retuner(
    _ row: [NSView], _ format: @escaping (Double) -> String
) -> (Double) -> Void {
    let slider = row.compactMap { $0 as? NSSlider }.first
    let readout = row.compactMap { $0 as? NSTextField }.last
    return { value in
        slider?.doubleValue = value
        readout?.stringValue = format(value)
    }
}

/// Prefill defence. A meta may hold anything a host wrote, and a slider
/// silently clamps its own position while this dialog's stored state would
/// not — so both are built from the one clamped value here.
private func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}
