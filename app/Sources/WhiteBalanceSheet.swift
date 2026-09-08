import AppKit

/// The White Balance dialog: a Temperature slider, a Tint slider and an
/// "As shot" reset to the exact identity.
///
/// Every parameter, range and default comes from `AdjustmentSchema`; the
/// lifecycle — the captured handles, the debounced in-context preview, one
/// undo step on Apply and nothing on Cancel — is `AdjustmentSheet`'s, in all
/// three modes (Image ▸ Adjustments, Layer ▸ New Adjustment Layer, and
/// Adjustment Options… on an existing layer).
///
/// The pair describes the ILLUMINANT the pixels were shot under, and the op
/// Bradford-adapts that white to D65 — so a HIGHER kelvin WARMS the picture
/// and a POSITIVE tint pushes it toward MAGENTA (Camera Raw's directions,
/// not the physicist's). The adaptation is computed with the sRGB transfer
/// function and the sRGB (D65) primaries whatever profile the document
/// carries, because an adjustment is a pure function of the numbers the
/// document already holds; and 6504 K / 0 is the EXACT identity, snapped in
/// the core rather than left to the accuracy of a CCT fit. The caption
/// states all three, since a 10 pt footnote shares its line with the two
/// buttons and has room for about thirty characters.
final class WhiteBalanceSheet: AdjustmentSheet {
    /// The daylight white every camera and every photographer treats as
    /// neutral, and the one temperature the core snaps to an exact identity
    /// matrix — which is why the reset button names it.
    private static let asShotKelvin = 6504.0
    private static let asShotTint = 0.0

    /// The control values, read lazily rather than in an initializer:
    /// `initial` is the base class's `let`, so the first touch of either —
    /// always `makeContent()`, which runs after init — is where the layer's
    /// own values (or the schema's defaults) land.
    private lazy var kelvin = number("temperature").value
    private lazy var tint = number("tint").value

    /// The two controls the reset writes back into. `sliderRow` builds them
    /// and hands them back in column order — label, slider, readout — so a
    /// sheet with a reset button reaches them this way rather than
    /// duplicating the house row.
    private var temperatureControls: (slider: NSSlider, readout: NSTextField)?
    private var tintControls: (slider: NSSlider, readout: NSTextField)?

    override func makeContent() -> NSView {
        let temperatureRow = number("temperature")
        let tintRow = number("tint")
        let kelvinRange = temperatureRow.range

        let temperatureViews = sliderRow(
            "Temperature:", range: Self.sliderRange(forKelvin: kelvinRange),
            value: Self.sliderValue(forKelvin: kelvin),
            format: { Self.kelvinReadout(Self.kelvin(atSlider: $0, in: kelvinRange)) },
            onChange: { [weak self] value in
                self?.kelvin = Self.kelvin(atSlider: value, in: kelvinRange)
            })
        let tintViews = sliderRow(
            "Tint:", range: tintRow.range, value: tint,
            format: { Self.tintReadout($0.rounded()) },
            onChange: { [weak self] value in self?.tint = value.rounded() })
        temperatureControls = Self.controls(of: temperatureViews)
        tintControls = Self.controls(of: tintViews)

        let reset = StickerButton(
            title: "As shot (6504 K / 0)", style: .secondary, target: self,
            action: #selector(asShotClicked(_:)))
        let grid = Self.grid([
            temperatureViews, tintViews, [NSGridCell.emptyContentView, reset],
        ])

        let caption = NSTextField(
            wrappingLabelWithString:
                "The pair describes the light the pixels were shot under, and the op adapts "
                + "that white to D65 — so a higher kelvin warms the picture and a positive "
                + "tint pushes it toward magenta. The adaptation is computed in sRGB "
                + "primaries whatever profile the document carries, and 6504 K with tint 0 "
                + "is the exact identity.")
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
        ["temperature": kelvin, "tint": tint]
    }

    /// The direction, which is the one thing a reader must not guess at;
    /// the caption above carries the primaries and the identity.
    override var footnote: String { "higher K warms · one undo step" }

    /// Back to the identity in one click. The values are written exactly —
    /// 6504 and 0, not the nearest handle position — because that pair is
    /// what the core snaps to an identity matrix.
    @objc private func asShotClicked(_ sender: Any?) {
        kelvin = Self.asShotKelvin
        tint = Self.asShotTint
        if let controls = temperatureControls {
            controls.slider.doubleValue = Self.sliderValue(forKelvin: kelvin)
            controls.readout.stringValue = Self.kelvinReadout(kelvin)
        }
        if let controls = tintControls {
            controls.slider.doubleValue = tint
            controls.readout.stringValue = Self.tintReadout(tint)
        }
        valuesChanged()
    }

    // MARK: - The mired temperature axis

    /// What the temperature handle carries: MIRED (10⁶ / K), negated so
    /// kelvin still rises to the right. Mired is the scale colour
    /// temperature actually behaves on — 2000 → 3000 K is a transformation
    /// of the picture while 9000 → 10000 K is barely visible, and equal
    /// mired steps are equal visual shifts, which is why filters have been
    /// graded in mireds since long before sliders existed. On a linear
    /// kelvin track the whole tungsten-to-daylight range would live in the
    /// first fifth of the slider.
    private static func sliderValue(forKelvin kelvin: Double) -> Double {
        -1e6 / max(kelvin, 1)
    }

    /// The kelvin a handle position names, rounded to the whole degree the
    /// readout shows (so what is stored is what was read) and clamped into
    /// the schema's range.
    private static func kelvin(atSlider value: Double, in range: ClosedRange<Double>) -> Double {
        let kelvin = -1e6 / min(value, -1e-6)
        return min(max(kelvin.rounded(), range.lowerBound), range.upperBound)
    }

    /// The handle's own range, derived from the schema's temperature range:
    /// the negated reciprocal is monotone, so the ends map straight over.
    private static func sliderRange(forKelvin range: ClosedRange<Double>) -> ClosedRange<Double> {
        sliderValue(forKelvin: range.lowerBound)...sliderValue(forKelvin: range.upperBound)
    }

    private static func kelvinReadout(_ kelvin: Double) -> String {
        String(format: "%.0f K", kelvin)
    }

    private static func tintReadout(_ tint: Double) -> String {
        String(format: "%+.0f", tint)
    }

    /// The slider and the readout of a house row, by their column
    /// positions; nil if the row is ever built some other way, in which
    /// case the reset button simply leaves the handles where they are
    /// rather than lying about them.
    private static func controls(of row: [NSView]) -> (slider: NSSlider, readout: NSTextField)? {
        guard row.count == 3, let slider = row[1] as? NSSlider,
              let readout = row[2] as? NSTextField
        else { return nil }
        return (slider, readout)
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
