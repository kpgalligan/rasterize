import AppKit

/// The Exposure dialog: exposure in stops, an offset, and a REVERSED
/// log-feel gamma slider.
///
/// Every parameter, range and default comes from `AdjustmentSchema`; the
/// lifecycle — the captured handles, the debounced in-context preview, one
/// undo step on Apply and nothing on Cancel — is `AdjustmentSheet`'s, in all
/// three modes (Image ▸ Adjustments, Layer ▸ New Adjustment Layer, and
/// Adjustment Options… on an existing layer).
///
/// The gamma slider is the one control in the app drawn against its own
/// axis — 9.99 at the LEFT, 0.01 at the right — because this is Photoshop's
/// EXPOSURE gamma, applied as a power, so a value above 1 DARKENS. Drawing
/// it the usual way round would mean dragging right to darken, which no
/// other tonal control in the app does; drawn reversed, the handle still
/// moves right to lighten and only the number falls. That is the inverse of
/// the Levels dialog's midtone gamma, which sits two items away in the same
/// menu, so both the caption and the footnote say which convention this is.
final class ExposureSheet: AdjustmentSheet {
    /// The control values, read lazily rather than in an initializer:
    /// `initial` is the base class's `let`, so the first touch of any of
    /// these — always `makeContent()`, which runs after init — is where the
    /// layer's own values (or the schema's defaults) land.
    private lazy var stops = number("exposure").value
    private lazy var offset = number("offset").value
    private lazy var gamma = number("gamma").value

    override func makeContent() -> NSView {
        let exposureRow = number("exposure")
        let offsetRow = number("offset")
        let gammaRow = number("gamma")
        let gammaRange = gammaRow.range

        let grid = Self.grid([
            // Photoshop's own precisions: stops to two places, the offset to
            // four (it moves the black point, where a ten-thousandth of the
            // range is still visible), gamma to two.
            sliderRow(
                "Exposure:", range: exposureRow.range, value: stops,
                format: { String(format: "%+.2f", $0) },
                onChange: { [weak self] value in self?.stops = Self.snapped(value, to: 100) }),
            sliderRow(
                "Offset:", range: offsetRow.range, value: offset,
                format: { String(format: "%+.4f", $0) },
                onChange: { [weak self] value in self?.offset = Self.snapped(value, to: 10000) }),
            sliderRow(
                "Gamma:", range: Self.sliderRange(forGamma: gammaRange),
                value: Self.sliderValue(forGamma: gamma),
                format: { String(format: "%.2f", Self.gamma(atSlider: $0, in: gammaRange)) },
                onChange: { [weak self] value in
                    self?.gamma = Self.gamma(atSlider: value, in: gammaRange)
                }),
        ])

        let caption = NSTextField(
            wrappingLabelWithString:
                "The stops scale the pixels in linear light and the offset lifts or drops "
                + "the black point; gamma is applied last, as a POWER, so above 1 it "
                + "darkens. That is Photoshop's Exposure convention — the inverse of the "
                + "Levels dialog's midtone gamma — which is why the gamma slider runs 9.99 "
                + "to 0.01 and the picture still brightens as the handle moves right.")
        caption.font = DS.sans(12)
        caption.textColor = DS.textMuted
        caption.preferredMaxLayoutWidth = sheetWidth - sheetInset * 2

        let content = NSStackView(views: [grid, caption])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        return content
    }

    override func currentParams() -> [String: Any] {
        ["exposure": stops, "offset": offset, "gamma": gamma]
    }

    /// The convention worth stating beside the buttons; the caption above
    /// carries the rest (a 10 pt footnote shares its line with the two
    /// buttons and has room for about thirty characters).
    override var footnote: String { "gamma > 1 darkens · one undo" }

    // MARK: - The reversed, log-feel gamma axis

    /// What the gamma handle carries: −log10(gamma). The logarithm is the
    /// Levels dialog's log feel (a constant RATIO per handle step, so 0.5
    /// and 2 sit the same distance from 1), and the negation is what
    /// reverses the axis.
    private static func sliderValue(forGamma gamma: Double) -> Double {
        -log10(max(gamma, 0.0001))
    }

    /// The gamma a handle position names: snapped to the two decimals the
    /// readout shows and clamped into the schema's range, so the value
    /// written can never be one the core would refuse.
    private static func gamma(atSlider value: Double, in range: ClosedRange<Double>) -> Double {
        min(max(snapped(pow(10, -value), to: 100), range.lowerBound), range.upperBound)
    }

    /// `value` rounded to the resolution its readout shows. The meta must
    /// not carry precision the dialog cannot display: a re-opened layer
    /// would otherwise show numbers that are not quite the ones that made
    /// its pixels. Values the sheet only READS are left exactly as they
    /// are, so re-committing an untouched layer stays a no-op.
    private static func snapped(_ value: Double, to scale: Double) -> Double {
        (value * scale).rounded() / scale
    }

    /// The handle's own range, derived from the schema's gamma range with
    /// the ends swapped — the reversal is spelled exactly once, here.
    private static func sliderRange(forGamma range: ClosedRange<Double>) -> ClosedRange<Double> {
        sliderValue(forGamma: range.upperBound)...sliderValue(forGamma: range.lowerBound)
    }

    // MARK: - Schema reads

    /// The value a control opens on and the range it moves in, both from
    /// `AdjustmentSchema`'s row for `key` — so a slider's endpoints and the
    /// MCP validator's refusals are literally the same numbers, and a meta
    /// from a newer build (or a hand-written one) cannot put a handle off
    /// its own slider. The fallback is unreachable: the keys below are that
    /// table's own rows, and it exists only so the dialog still opens if the
    /// table is ever edited out from under it.
    private func number(_ key: String) -> (value: Double, range: ClosedRange<Double>) {
        guard let param = AdjustmentSchema.params(for: op).first(where: { $0.key == key }),
              case .number(let range, let fallback) = param.kind
        else { return (0, 0...1) }
        let raw = initial.number(key, default: fallback)
        return (min(max(raw, range.lowerBound), range.upperBound), range)
    }
}
