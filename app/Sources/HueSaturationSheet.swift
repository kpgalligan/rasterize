import AppKit

/// The Hue/Saturation dialog — the workhorse of the batch. A range popup
/// (Master plus the six editable hue bands) chooses which part of the ONE
/// params object the Hue / Saturation / Lightness trio writes into; a
/// Colorize checkbox swaps that trio for its own three (hue 0…360,
/// saturation 0…100, lightness ±100), exactly as Photoshop's does; and a
/// selected band also shows where it sits on the wheel — Center, Inner and
/// Falloff, the three numbers behind the core's band ramp.
///
/// Two rules the params follow, both worth stating because they are what
/// keeps the meta small and a re-commit byte-stable:
///
/// - **A band whose three edits are all zero is left out entirely.** Its
///   placement then has nothing to weight, so the picture is identical and
///   the `.rz` (and every `get_document` reply) is shorter.
/// - **The master and band values are written even while Colorize is on**,
///   where the core ignores them: unchecking the box must bring back the
///   edit the user made before checking it.
///
/// Every parameter, range and default comes from `AdjustmentSchema`; the
/// lifecycle — the captured handles, the debounced in-context preview, one
/// undo step on Apply and nothing on Cancel — is `AdjustmentSheet`'s, in all
/// three modes (Image ▸ Adjustments, Layer ▸ New Adjustment Layer, and
/// Adjustment Options… on an existing layer).
final class HueSaturationSheet: AdjustmentSheet {
    /// One range's three edits: degrees for hue, unit floats for saturation
    /// and lightness, exactly as the meta stores them.
    private struct Edits {
        var hue: Double = 0
        var saturation: Double = 0
        var lightness: Double = 0

        /// True when the range moves nothing, which is what lets its band
        /// be dropped from the params.
        var isIdentity: Bool { hue == 0 && saturation == 0 && lightness == 0 }
    }

    /// Where a band sits on the wheel: the centre of its flat top, that
    /// top's half-width (`inner`), and the linear ramp beyond it
    /// (`falloff`) — the three numbers the core's `band_weight` reads. The
    /// factory 15°/30° pair is what makes adjacent bands sum to exactly 1,
    /// so editing all six the same way IS one master edit; a user who
    /// widens one band is deliberately leaving that property behind.
    private struct Placement {
        var center: Double
        var inner: Double
        var falloff: Double
    }

    /// The grid rows this dialog shows and hides. `makeContent` builds them
    /// once, in this order — the range popup (row 0, always shown), the
    /// shift trio, Colorize's own trio, the Colorize checkbox (row 7, always
    /// shown), then the selected band's placement — so a row's index is a
    /// constant.
    private enum Row {
        static let edits = 1...3
        static let colorize = 4...6
        static let placement = 8...10
    }

    /// The schema's hue range is the half-open [0, 360) — 360 and 0 are the
    /// same angle and the core refuses the spelling that says both — so
    /// every hue-position slider stops one degree short.
    private static let maxHue = 359.0

    private var master = Edits()
    private var bandEdits: [Edits] = []
    private var placements: [Placement] = []
    private var colorize = false
    private var colorizeHue: Double = 0
    private var colorizeSaturation = 0.25
    private var colorizeLightness: Double = 0
    /// 0 = Master, 1…6 = `AdjustmentSchema.hueBands` in order.
    private var range = 0

    private weak var grid: NSGridView?
    /// Greyed rather than hidden while Colorize is on: a disabled control
    /// says "not in effect" without the rows below it jumping.
    private weak var rangePopup: NSPopUpButton?
    /// The retuners for the six sliders the popup re-points: three edits,
    /// three placements. Assigned in `makeContent`, in row order.
    private var showEdit: [(Double) -> Void] = []
    private var showPlacement: [(Double) -> Void] = []

    override init(
        op: AdjustmentLayerOp, document: ImageDocument, canvas: ImageCanvasView,
        mode: AdjustmentSheetMode
    ) {
        super.init(op: op, document: document, canvas: canvas, mode: mode)
        master = Edits(
            hue: clamped(initial.number("hue", default: 0), -180...180),
            saturation: clamped(initial.number("saturation", default: 0), -1...1),
            lightness: clamped(initial.number("lightness", default: 0), -1...1))
        colorize = initial.bool("colorize", default: false)
        colorizeHue = clamped(initial.number("colorize_hue", default: 0), 0...Self.maxHue)
        colorizeSaturation = clamped(initial.number("colorize_saturation", default: 0.25), 0...1)
        colorizeLightness = clamped(initial.number("colorize_lightness", default: 0), -1...1)
        // A band the params omit is the schema's defaults, so the two are
        // merged before reading: what the layer says wins, and every key it
        // leaves out (which is all of them for an untouched band) comes
        // back as the factory placement rather than as zero.
        let stored = initial.object("bands")
        for (index, name) in AdjustmentSchema.hueBands.enumerated() {
            var merged = AdjustmentSchema.objectDefaults(for: op, path: ["bands", name])
            if let band = stored?[name] as? [String: Any] {
                merged.merge(band) { _, new in new }
            }
            let band = AdjustmentLayerPayload(op: op, params: merged)
            bandEdits.append(
                Edits(
                    hue: clamped(band.number("hue", default: 0), -180...180),
                    saturation: clamped(band.number("saturation", default: 0), -1...1),
                    lightness: clamped(band.number("lightness", default: 0), -1...1)))
            placements.append(
                Placement(
                    center: clamped(
                        band.number("center", default: Double(index) * 60), 0...Self.maxHue),
                    inner: clamped(band.number("inner", default: 15), 0...180),
                    falloff: clamped(band.number("falloff", default: 30), 0...180)))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HueSaturationSheet does not support NSCoder")
    }

    override func makeContent() -> NSView {
        let edits = self.edits(for: range)
        let placement = self.placement(for: range)

        let rangeRow = popupRow(
            "Range:", titles: ["Master"] + AdjustmentSchema.hueBands.map { $0.capitalized },
            selected: range
        ) { [weak self] index in self?.selectRange(index) }
        rangePopup = rangeRow.compactMap { $0 as? NSPopUpButton }.first

        // The trio the popup re-points. Every write goes through `edit`, so
        // the slider never needs to know which range it is editing.
        let hueRow = sliderRow(
            "Hue:", range: -180...180, value: edits.hue, format: degreeText
        ) { [weak self] value in self?.edit { $0.hue = value.rounded() } }
        let saturationRow = sliderRow(
            "Saturation:", range: -100...100, value: edits.saturation * 100, format: percentText
        ) { [weak self] value in self?.edit { $0.saturation = value.rounded() / 100 } }
        let lightnessRow = sliderRow(
            "Lightness:", range: -100...100, value: edits.lightness * 100, format: percentText
        ) { [weak self] value in self?.edit { $0.lightness = value.rounded() / 100 } }

        // Colorize's own three. They carry the same labels because only one
        // trio is ever on screen, and they are separate parameters — the
        // core reads `colorize_*` and ignores the shift controls entirely,
        // so a user who unchecks the box gets their shift edit back.
        let colorizeHueRow = sliderRow(
            "Hue:", range: 0...Self.maxHue, value: colorizeHue, format: degreeText
        ) { [weak self] value in self?.colorizeHue = value.rounded() }
        let colorizeSaturationRow = sliderRow(
            "Saturation:", range: 0...100, value: colorizeSaturation * 100, format: percentText
        ) { [weak self] value in self?.colorizeSaturation = value.rounded() / 100 }
        let colorizeLightnessRow = sliderRow(
            "Lightness:", range: -100...100, value: colorizeLightness * 100, format: percentText
        ) { [weak self] value in self?.colorizeLightness = value.rounded() / 100 }

        let colorizeRow = checkboxRow("Colorize", value: colorize) { [weak self] on in
            self?.setColorize(on)
        }

        let centerRow = sliderRow(
            "Center:", range: 0...Self.maxHue, value: placement.center, format: degreeText
        ) { [weak self] value in self?.place { $0.center = value.rounded() } }
        let innerRow = sliderRow(
            "Inner:", range: 0...180, value: placement.inner, format: degreeText
        ) { [weak self] value in self?.place { $0.inner = value.rounded() } }
        let falloffRow = sliderRow(
            "Falloff:", range: 0...180, value: placement.falloff, format: degreeText
        ) { [weak self] value in self?.place { $0.falloff = value.rounded() } }

        showEdit = [
            retuner(hueRow, degreeText), retuner(saturationRow, percentText),
            retuner(lightnessRow, percentText),
        ]
        showPlacement = [
            retuner(centerRow, degreeText), retuner(innerRow, degreeText),
            retuner(falloffRow, degreeText),
        ]

        let grid = AdjustmentSheet.grid([
            rangeRow, hueRow, saturationRow, lightnessRow,
            colorizeHueRow, colorizeSaturationRow, colorizeLightnessRow,
            colorizeRow, centerRow, innerRow, falloffRow,
        ])
        self.grid = grid
        updateVisibility()
        return grid
    }

    override func currentParams() -> [String: Any] {
        var params: [String: Any] = [
            "hue": master.hue,
            "saturation": master.saturation,
            "lightness": master.lightness,
            "colorize": colorize,
            "colorize_hue": colorizeHue,
            "colorize_saturation": colorizeSaturation,
            "colorize_lightness": colorizeLightness,
        ]
        var bands: [String: Any] = [:]
        for (index, name) in AdjustmentSchema.hueBands.enumerated() {
            guard bandEdits.indices.contains(index), placements.indices.contains(index)
            else { continue }
            let edits = bandEdits[index]
            // A band that moves nothing is left out entirely: same picture,
            // shorter meta, and a re-commit that changes no bytes.
            guard !edits.isIdentity else { continue }
            let placement = placements[index]
            bands[name] = [
                "hue": edits.hue,
                "saturation": edits.saturation,
                "lightness": edits.lightness,
                "center": placement.center,
                "inner": placement.inner,
                "falloff": placement.falloff,
            ]
        }
        if !bands.isEmpty { params["bands"] = bands }
        return params
    }

    /// Colorize is the one control here whose meaning is not obvious from
    /// the sliders it leaves on screen: it REPLACES the hue and saturation
    /// of every pixel rather than shifting them, so the range popup and the
    /// shift trio have nothing to do while it is on.
    override var footnote: String { "Colorize replaces, not shifts" }

    // MARK: - The selected range

    private func edits(for range: Int) -> Edits {
        guard range > 0, bandEdits.indices.contains(range - 1) else { return master }
        return bandEdits[range - 1]
    }

    /// Master has no placement of its own; the popup hides those rows for
    /// it, and this answers with the first band's so the accessor stays
    /// total (the factory 15°/30° pair when there is no band at all).
    private func placement(for range: Int) -> Placement {
        let index = max(range - 1, 0)
        guard placements.indices.contains(index) else {
            return Placement(center: 0, inner: 15, falloff: 30)
        }
        return placements[index]
    }

    private func edit(_ change: (inout Edits) -> Void) {
        guard range > 0 else {
            change(&master)
            return
        }
        guard bandEdits.indices.contains(range - 1) else { return }
        change(&bandEdits[range - 1])
    }

    private func place(_ change: (inout Placement) -> Void) {
        guard range > 0, placements.indices.contains(range - 1) else { return }
        change(&placements[range - 1])
    }

    private func selectRange(_ index: Int) {
        range = min(max(index, 0), AdjustmentSchema.hueBands.count)
        let edits = self.edits(for: range)
        let values = [edits.hue, edits.saturation * 100, edits.lightness * 100]
        for (show, value) in zip(showEdit, values) { show(value) }
        if range > 0 {
            let placement = self.placement(for: range)
            let values = [placement.center, placement.inner, placement.falloff]
            for (show, value) in zip(showPlacement, values) { show(value) }
        }
        updateVisibility()
    }

    private func setColorize(_ on: Bool) {
        colorize = on
        updateVisibility()
    }

    /// Colorize takes the shift trio off the sheet and greys the range
    /// popup: the core ignores both while it is on, so leaving them live
    /// would promise an edit that does not happen. The placement rows
    /// belong to a band and appear only when one is selected.
    private func updateVisibility() {
        rangePopup?.isEnabled = !colorize
        for index in Row.edits { setRow(index, visible: !colorize) }
        for index in Row.colorize { setRow(index, visible: colorize) }
        for index in Row.placement { setRow(index, visible: !colorize && range > 0) }
    }

    private func setRow(_ index: Int, visible: Bool) {
        guard let grid = grid, index < grid.numberOfRows else { return }
        grid.row(at: index).isHidden = !visible
    }
}

/// Degrees, whole ones: what the rows write is `rounded()`, so the readout
/// and the stored parameter are the same number.
private let degreeText: (Double) -> String = { String(format: "%.0f°", $0) }

/// Photoshop's ±100 readout for a slider whose stored value is that over
/// 100 (the phase's numeric convention).
private let percentText: (Double) -> String = { String(format: "%.0f%%", $0) }

/// A setter that shows a value in the house slider row it was built from.
/// `AdjustmentSheet.sliderRow` returns the row as `[label, slider,
/// readout]` and hands back no handles, and this dialog retunes the SAME
/// three sliders when the range popup moves rather than building a set per
/// range — so it takes the two controls back out of the array. Setting the
/// slider's value fires no action, which is what the caller wants: it
/// retunes several rows and previews once at the end.
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
