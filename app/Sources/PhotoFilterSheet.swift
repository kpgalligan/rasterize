import AppKit

/// The Photo Filter dialog: the standard filter presets, the colour they
/// select, Density, and Preserve Luminosity.
///
/// The preset table is the one thing here that is not a slider, and it is
/// where two colour rules meet. A stored adjustment colour is always the
/// DOCUMENT's numbers (`AdjustmentColor`) — an adjustment is a function of
/// the pixels it transforms, so its parameters live in their space — while
/// a NAMED filter is an authored sRGB colour: "#ec8a00" really is Warming
/// 85 *in sRGB*, and on a Display P3 document those same bytes are a
/// visibly different orange. So every entry below is sRGB and converts
/// exactly ONCE, at the moment it is picked
/// (`AdjustmentColor.documentHex(forSRGBHex:in:)`), after which it is the
/// document's numbers like any other adjustment colour. Opening a new sheet
/// counts as picking the factory preset; re-opening an existing layer does
/// not, because that layer's colour was converted when it was authored.
///
/// Every parameter, range and default comes from `AdjustmentSchema`; the
/// lifecycle — the captured handles, the debounced in-context preview, one
/// undo step on Apply and nothing on Cancel — is `AdjustmentSheet`'s, in all
/// three modes (Image ▸ Adjustments, Layer ▸ New Adjustment Layer, and
/// Adjustment Options… on an existing layer).
final class PhotoFilterSheet: AdjustmentSheet {
    /// One entry of the standard table: the name Photoshop gives the filter
    /// and its AUTHORED sRGB colour (see the class doc).
    private struct Preset {
        let name: String
        let srgbHex: String
    }

    /// The eight standard filters: the three warming and three cooling
    /// conversion filters photographers know by their Wratten/Kodak
    /// numbers, plus the two named colour filters.
    private static let presets: [Preset] = [
        Preset(name: "Warming Filter (85)", srgbHex: AdjustmentSchema.warming85),
        Preset(name: "Warming Filter (LBA)", srgbHex: "#fa9600"),
        Preset(name: "Warming Filter (81)", srgbHex: "#ebb113"),
        Preset(name: "Cooling Filter (80)", srgbHex: "#006dff"),
        Preset(name: "Cooling Filter (LBB)", srgbHex: "#005dff"),
        Preset(name: "Cooling Filter (82)", srgbHex: "#00b5ff"),
        Preset(name: "Sepia", srgbHex: "#ac7a33"),
        Preset(name: "Underwater", srgbHex: "#00c2b1"),
    ]
    /// The popup's last item, which selects nothing: it is what the popup
    /// shows once the well holds a colour no preset names.
    private static let customTitle = "Custom…"

    /// The table in the DOCUMENT's numbers, converted once at open. Both
    /// directions read it: picking a preset stores its entry, and picking a
    /// colour in the well looks the colour up here to decide whether the
    /// popup still names a filter.
    private var presetHexes: [String] = []
    private var colorHex = AdjustmentSchema.warming85
    private var density = 0.25
    private var preserveLuminosity = true
    private weak var presetPopup: NSPopUpButton?
    private weak var colorWell: NSColorWell?

    override init(
        op: AdjustmentLayerOp, document: ImageDocument, canvas: ImageCanvasView,
        mode: AdjustmentSheetMode
    ) {
        super.init(op: op, document: document, canvas: canvas, mode: mode)
        presetHexes = Self.presets.map {
            AdjustmentColor.documentHex(forSRGBHex: $0.srgbHex, in: documentColorSpace)
        }
        let stored = initial.colorHex("color", default: AdjustmentSchema.warming85)
        switch mode {
        case .edit:
            // The layer's own colour is already the document's numbers —
            // converting it again would move it a little further from the
            // filter it names on every re-open.
            colorHex = stored
        case .create, .destructive:
            // A new sheet opens on the schema's default, which is the sRGB
            // SPELLING of Warming 85. That is the factory preset being
            // picked, so it converts here exactly as the popup would.
            colorHex = AdjustmentColor.documentHex(forSRGBHex: stored, in: documentColorSpace)
        }
        density = clamped(initial.number("density", default: 0.25), 0...1)
        preserveLuminosity = initial.bool("preserve_luminosity", default: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PhotoFilterSheet does not support NSCoder")
    }

    override func makeContent() -> NSView {
        let presetRow = popupRow(
            "Filter:", titles: Self.presets.map { $0.name } + [Self.customTitle],
            selected: presetIndex()
        ) { [weak self] index in self?.selectPreset(index) }
        presetPopup = presetRow.compactMap { $0 as? NSPopUpButton }.first

        let colorViews = colorRow("Color:", hex: colorHex) { [weak self] hex in
            self?.setColor(hex)
        }
        colorWell = colorViews.compactMap { $0 as? NSColorWell }.first

        let densityRow = sliderRow(
            "Density:", range: 0...100, value: density * 100, format: percentText
        ) { [weak self] value in self?.density = value.rounded() / 100 }
        let preserveRow = checkboxRow(
            "Preserve Luminosity", value: preserveLuminosity
        ) { [weak self] on in self?.preserveLuminosity = on }

        return AdjustmentSheet.grid([presetRow, colorViews, densityRow, preserveRow])
    }

    override func currentParams() -> [String: Any] {
        [
            "color": colorHex,
            "density": density,
            "preserve_luminosity": preserveLuminosity,
        ]
    }

    /// Why the swatch on a wide-gamut document does not hold the hex the
    /// filter is famous for.
    override var footnote: String { "presets are sRGB, converted on pick" }

    // MARK: - Preset and colour, which follow each other

    /// The popup row a colour selects: the filter it names, or Custom…
    private func presetIndex() -> Int {
        presetHexes.firstIndex(of: colorHex) ?? Self.presets.count
    }

    /// Picking a filter writes its colour; picking Custom… writes nothing,
    /// because the colour the user already has IS the custom one.
    private func selectPreset(_ index: Int) {
        guard presetHexes.indices.contains(index) else { return }
        colorHex = presetHexes[index]
        colorWell?.color =
            AdjustmentColor.color(fromHex: colorHex, in: documentColorSpace) ?? .black
    }

    /// A colour dropped or picked in the well is already the document's
    /// numbers (the well was built in the document's space). It moves the
    /// popup: back onto a filter when it lands exactly on one, onto
    /// Custom… otherwise.
    private func setColor(_ hex: String) {
        colorHex = hex
        presetPopup?.selectItem(at: presetIndex())
    }
}

/// Density as a percent, which is how every version of this dialog has
/// shown it, over the core's [0, 1] (the phase's numeric convention).
/// Whole numbers only, because what the row writes is `rounded() / 100`.
private let percentText: (Double) -> String = { String(format: "%.0f%%", $0) }

/// Prefill defence. A meta may hold anything a host wrote, and a slider
/// silently clamps its own position while this dialog's stored state would
/// not — so both are built from the one clamped value here.
private func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}
