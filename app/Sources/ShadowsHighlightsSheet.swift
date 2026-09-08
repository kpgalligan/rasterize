import AppKit

/// The Shadows/Highlights dialog: grouped rows — Shadows (Amount, Tone),
/// Highlights (Amount, Tone), then the shared Radius, Color and Midtone
/// controls, in Photoshop's own three blocks.
///
/// Every parameter, range and default comes from `AdjustmentSchema`; the
/// lifecycle — the captured handles, the debounced in-context preview, one
/// undo step on Apply and nothing on Cancel — is `AdjustmentSheet`'s, in all
/// three modes (Image ▸ Adjustments, Layer ▸ New Adjustment Layer, and
/// Adjustment Options… on an existing layer).
///
/// This is the one SPATIAL adjustment, and Radius is a plane parameter:
/// every change of it rebuilds the alpha-weighted blur of the luma the two
/// bands are weighted by. That work happens on `AdjustmentSheet`'s preview
/// queue behind its 60 ms debounce, which is why nothing here re-renders on
/// its own — the house slider row updates only its readout as the handle
/// moves, and the picture follows once the drag settles.
final class ShadowsHighlightsSheet: AdjustmentSheet {
    /// The control values, read lazily rather than in an initializer:
    /// `initial` is the base class's `let`, so the first touch of any of
    /// these — always `makeContent()`, which runs after init — is where the
    /// layer's own values (or the schema's defaults) land.
    private lazy var shadowsAmount = number("shadows", "amount").value
    private lazy var shadowsTone = number("shadows", "tone").value
    private lazy var highlightsAmount = number("highlights", "amount").value
    private lazy var highlightsTone = number("highlights", "tone").value
    private lazy var radius = number("radius").value
    private lazy var color = number("color").value
    private lazy var midtoneContrast = number("midtone_contrast").value

    /// Photoshop's percent, from the core's unit float (§1.1's rule: the
    /// meta stores the fraction, the dialog shows the percentage).
    private static let percent: (Double) -> String = {
        String(format: "%.0f %%", $0 * 100)
    }
    /// The same, for a two-sided control where the sign carries meaning.
    private static let signedPercent: (Double) -> String = {
        String(format: "%+.0f %%", $0 * 100)
    }

    override func makeContent() -> NSView {
        let shadows = Self.grid([
            bandRow("Amount:", "shadows", "amount", { [weak self] in self?.shadowsAmount = $0 }),
            bandRow("Tone:", "shadows", "tone", { [weak self] in self?.shadowsTone = $0 }),
        ])
        let highlights = Self.grid([
            bandRow(
                "Amount:", "highlights", "amount",
                { [weak self] in self?.highlightsAmount = $0 }),
            bandRow("Tone:", "highlights", "tone", { [weak self] in self?.highlightsTone = $0 }),
        ])

        let radiusRow = number("radius")
        let colorRow = number("color")
        let midtoneRow = number("midtone_contrast")
        let radiusRange = radiusRow.range
        let adjustments = Self.grid([
            sliderRow(
                "Radius:", range: Self.radiusSliderRange,
                value: Self.sliderValue(forRadius: radius, in: radiusRange),
                format: { String(format: "%.0f px", Self.radius(atSlider: $0, in: radiusRange)) },
                onChange: { [weak self] value in
                    self?.radius = Self.radius(atSlider: value, in: radiusRange)
                }),
            sliderRow(
                "Color:", range: colorRow.range, value: color, format: Self.signedPercent,
                onChange: { [weak self] value in self?.color = Self.snapped(value, to: 100) }),
            // Photoshop's Adjustments block labels this one "Midtone"; the
            // longer "Midtone Contrast" does not fit the sheets' 106 pt
            // label column, and the caption below says what it bends.
            sliderRow(
                "Midtone:", range: midtoneRow.range, value: midtoneContrast,
                format: Self.signedPercent,
                onChange: { [weak self] value in
                    self?.midtoneContrast = Self.snapped(value, to: 100)
                }),
        ])

        let caption = NSTextField(
            wrappingLabelWithString:
                "Both bands are weighted by ONE large-radius, alpha-weighted blur of the "
                + "picture's own luma, so the lift follows the light in the scene rather "
                + "than the level alone and a cut-out gets no halo. Radius rebuilds that "
                + "estimate, so the preview waits for the drag to settle. Color saturates "
                + "only where the tone moved, and Midtone adds or removes contrast through "
                + "the middle; with both amounts and Midtone at 0 the pixels come back "
                + "exact, whatever Color says.")
        caption.font = DS.sans(12)
        caption.textColor = DS.textMuted
        caption.preferredMaxLayoutWidth = sheetWidth - sheetInset * 2

        let blocks: [NSView] = [
            microHeader("Shadows"), shadows,
            microHeader("Highlights"), highlights,
            microHeader("Adjustments"), adjustments,
            caption,
        ]
        let content = NSStackView(views: blocks)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        // A little air before each header, so the blocks read as blocks
        // rather than as one seven-row grid (Calculations' shape).
        content.setCustomSpacing(16, after: shadows)
        content.setCustomSpacing(16, after: highlights)
        content.setCustomSpacing(14, after: adjustments)
        return content
    }

    override func currentParams() -> [String: Any] {
        [
            "shadows": ["amount": shadowsAmount, "tone": shadowsTone],
            "highlights": ["amount": highlightsAmount, "tone": highlightsTone],
            "radius": radius,
            "color": color,
            "midtone_contrast": midtoneContrast,
        ]
    }

    // MARK: - Rows

    /// One row of a band block. Both bands carry the same two keys with the
    /// same ranges, so building them through one function is what keeps the
    /// two blocks identical.
    private func bandRow(
        _ label: String, _ block: String, _ key: String,
        _ onChange: @escaping (Double) -> Void
    ) -> [NSView] {
        let row = number(block, key)
        return sliderRow(
            label, range: row.range, value: row.value, format: Self.percent,
            onChange: { onChange(Self.snapped($0, to: 100)) })
    }

    private func microHeader(_ title: String) -> NSTextField {
        NSTextField(labelWithAttributedString: DS.microLabel(title))
    }

    // MARK: - The square-law radius axis

    /// The radius handle carries the square ROOT of the radius, so the
    /// useful band lands where the hand is. On a linear 0…1000 px track the
    /// default 30 px would sit 3 % from the left — five points of a 180 pt
    /// slider for the whole 10…150 px range every photograph actually uses —
    /// and this dialog has no number field to type into. Squaring puts 250
    /// px at the middle and leaves the small radii a third of the track.
    private static func sliderValue(
        forRadius radius: Double, in range: ClosedRange<Double>
    ) -> Double {
        sqrt(max(radius - range.lowerBound, 0) / span(range))
    }

    /// The radius a handle position names: whole pixels, which is what the
    /// readout shows and all the blur can resolve, clamped into the
    /// schema's range.
    private static func radius(atSlider value: Double, in range: ClosedRange<Double>) -> Double {
        let radius = (range.lowerBound + value * value * span(range)).rounded()
        return min(max(radius, range.lowerBound), range.upperBound)
    }

    /// `value` rounded to the resolution its readout shows. The meta must
    /// not carry precision the dialog cannot display: a re-opened layer
    /// would otherwise show numbers that are not quite the ones that made
    /// its pixels. Values the sheet only READS are left exactly as they
    /// are, so re-committing an untouched layer stays a no-op.
    private static func snapped(_ value: Double, to scale: Double) -> Double {
        (value * scale).rounded() / scale
    }

    /// The handle's own range: the square-root map is normalized, so it is
    /// 0…1 whatever the schema's radius range says.
    private static let radiusSliderRange = 0.0...1.0

    /// Never zero, so the map cannot produce a NaN if the schema's radius
    /// range is ever narrowed to a point.
    private static func span(_ range: ClosedRange<Double>) -> Double {
        max(range.upperBound - range.lowerBound, 1e-6)
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

    /// The same, for a key inside one of the two band blocks. A layer whose
    /// meta omits the block — the core reads an absent block as its
    /// defaults, so an agent may well write one that way — opens on the
    /// schema's defaults, which is exactly the picture that meta describes.
    private func number(
        _ block: String, _ key: String
    ) -> (value: Double, range: ClosedRange<Double>) {
        guard let outer = AdjustmentSchema.params(for: op).first(where: { $0.key == block }),
              case .object(let inner) = outer.kind,
              let param = inner.first(where: { $0.key == key }),
              case .number(let range, let fallback) = param.kind
        else { return (0, 0...1) }
        var raw = fallback
        if let object = initial.object(block),
           let value = (object[key] as? NSNumber)?.doubleValue, value.isFinite {
            raw = value
        }
        return (min(max(raw, range.lowerBound), range.upperBound), range)
    }
}
