import AppKit

/// A physical unit for the Image Size sheet's Resolution and Print size
/// rows.
///
/// The inch is the document's own unit — the core stores pixels per INCH —
/// so a centimetre is a display conversion and never a stored one.
enum PrintUnit: Int, CaseIterable {
    case inches
    case centimetres

    /// How many of this unit make one inch. 2.54 is exact by definition
    /// (the international inch, 1959) rather than a measurement, so the
    /// cm → inch → cm round trip loses nothing a three-decimal field could
    /// show.
    var perInch: Double {
        switch self {
        case .inches: return 1
        case .centimetres: return 2.54
        }
    }

    /// The Print size popup's title.
    var lengthTitle: String {
        switch self {
        case .inches: return "inches"
        case .centimetres: return "cm"
        }
    }

    /// The Resolution popup's title. A resolution is pixels PER unit, so it
    /// reads as a rate rather than as a unit name — Photoshop's wording.
    var resolutionTitle: String {
        switch self {
        case .inches: return "pixels/inch"
        case .centimetres: return "pixels/cm"
        }
    }
}

/// Pixels, print resolution and physical size, plus the arithmetic that ties
/// the three together: **print size = pixels / ppi**.
///
/// One implementation, shared by `ImageSizeSheetController` (which rebinds
/// the three against each other as the user types) and by
/// `ImageDocument+Print` (which needs the same physical size in points), so
/// the dialog's numbers and the printed page cannot disagree.
///
/// Every value is sanitized on the way in, which is what lets the rest of
/// the file divide without guarding: a resolution is never zero, never
/// negative and never NaN, and the pixel counts are never below one.
struct PrintSize {
    /// Points per inch. 72 is the PostScript point every AppKit page is
    /// measured in — not a screen scale factor, and not a resolution.
    static let pointsPerInch: Double = 72

    /// The range the core clamps a resolution into (`Resolution::sane`,
    /// behind `rz_doc_set_resolution`). Mirrored here so the sheet's fields
    /// refuse what the core would otherwise silently change under the user.
    static let ppiRange: ClosedRange<Double> = 1...30000

    /// The largest pixel count either axis takes: the Image Size sheet's own
    /// field maximum, kept here so that solving a printed length for pixels
    /// cannot propose a canvas the pixel fields themselves would refuse.
    static let maxPixelsPerAxis = 20000

    /// The pixel dimensions, at least 1 × 1.
    let pixels: (width: Int, height: Int)
    /// The print resolution per axis, inside `ppiRange`.
    let ppi: (x: Double, y: Double)

    init(pixels: (width: Int, height: Int), ppi: (x: Double, y: Double)) {
        self.pixels = (max(1, pixels.width), max(1, pixels.height))
        self.ppi = (PrintSize.sane(ppi.x), PrintSize.sane(ppi.y))
    }

    /// The core's `Resolution::sane` on this side: a non-finite or
    /// non-positive value becomes the 72 ppi default, anything else is
    /// clamped into `ppiRange`. Same rule, same numbers, so a value that
    /// survives here survives the FFI unchanged.
    static func sane(_ ppi: Double) -> Double {
        guard ppi.isFinite, ppi > 0 else { return 72 }
        return min(max(ppi, ppiRange.lowerBound), ppiRange.upperBound)
    }

    // MARK: - Reading the three out

    /// The printed size in `unit`, per axis: pixels / ppi.
    func size(in unit: PrintUnit) -> (width: Double, height: Double) {
        (Double(pixels.width) / ppi.x * unit.perInch,
         Double(pixels.height) / ppi.y * unit.perInch)
    }

    /// The resolution expressed in `unit` — pixels per inch over the number
    /// of units in an inch.
    func resolution(in unit: PrintUnit) -> (x: Double, y: Double) {
        (ppi.x / unit.perInch, ppi.y / unit.perInch)
    }

    /// A resolution typed into a field measured in `unit`, back in ppi.
    static func ppi(fromResolution value: Double, in unit: PrintUnit) -> Double {
        value * unit.perInch
    }

    /// A print resolution as one phrase: "300 ppi" when the two axes agree,
    /// "300 × 150 ppi" when they do not.
    ///
    /// The ONE spelling, because a document really can be anisotropic — the
    /// agent's `set_resolution` takes two numbers and a quarter turn swaps
    /// them — and every readout of that state has to say the same thing. The
    /// status bar and the export notice both come here; printing one axis as
    /// though it were the document's resolution is how they came to
    /// disagree.
    static func resolutionText(_ ppi: (x: Double, y: Double)) -> String {
        abs(ppi.x - ppi.y) < sameResolution
            ? "\(ppiText(ppi.x)) ppi" : "\(ppiText(ppi.x)) × \(ppiText(ppi.y)) ppi"
    }

    /// One ppi number with no trailing zeros: "300", not "300.0", and
    /// "144.5" when a document really is on a half.
    static func ppiText(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) <= 0.0001 { return String(Int(rounded)) }
        return String(format: "%g", value)
    }

    /// The printed size in points, which is what AppKit measures a page in.
    /// Floored at one point so a degenerate document cannot ask for a
    /// zero-sized page.
    var points: NSSize {
        let inches = size(in: .inches)
        return NSSize(
            width: max(inches.width * PrintSize.pointsPerInch, 1),
            height: max(inches.height * PrintSize.pointsPerInch, 1))
    }

    /// How far apart two ppi values may be and still BE the same number: the
    /// core quantizes a stored resolution to four decimals, so half a
    /// quantization step is the widest gap that can round to one value.
    /// Shared by the two questions that ask it — "is this an edit at all?"
    /// and "is this document anisotropic?" — so they cannot answer
    /// differently about one pair of numbers.
    private static let sameResolution = 5e-5

    /// Whether two resolutions agree to the four decimals the core
    /// quantizes to. The Image Size sheet asks this to decide whether it has
    /// a resolution edit to commit at all — committing one that quantizes to
    /// the same number would ask the core for a no-op and register a phantom
    /// undo step.
    func hasSameResolution(as other: PrintSize) -> Bool {
        abs(ppi.x - other.ppi.x) < PrintSize.sameResolution
            && abs(ppi.y - other.ppi.y) < PrintSize.sameResolution
    }

    // MARK: - Rebinding, holding the pixels (Resample off)

    /// A copy at a new, UNIFORM resolution with the pixels held: the print
    /// size follows.
    ///
    /// The sheet's Resolution row is a single field, as Photoshop's is, so
    /// it drives both axes. A document whose two axes differ — reachable
    /// only through the agent's `set_resolution` or by rotating such a
    /// document — is left alone until the user touches the field, and then
    /// becomes square.
    func settingResolution(_ resolution: Double) -> PrintSize {
        PrintSize(pixels: pixels, ppi: (resolution, resolution))
    }

    /// The resolution a printed `width` in `unit` implies, the pixels held.
    /// nil for a value a half-typed field can hold (empty, zero, negative).
    ///
    /// Uniform for the same reason `settingResolution` is: the printed
    /// height then follows the pixel aspect ratio, which is Photoshop's
    /// linked width / height / resolution with Resample off.
    func settingPrintWidth(_ width: Double, in unit: PrintUnit) -> PrintSize? {
        guard width.isFinite, width > 0 else { return nil }
        return settingResolution(Double(pixels.width) / (width / unit.perInch))
    }

    /// The resolution a printed `height` in `unit` implies, the pixels held.
    func settingPrintHeight(_ height: Double, in unit: PrintUnit) -> PrintSize? {
        guard height.isFinite, height > 0 else { return nil }
        return settingResolution(Double(pixels.height) / (height / unit.perInch))
    }

    // MARK: - Rebinding, holding the resolution (Resample on)

    /// A copy at new pixel dimensions with the resolution held: the print
    /// size follows.
    func settingPixels(width: Int, height: Int) -> PrintSize {
        PrintSize(pixels: (width, height), ppi: ppi)
    }

    /// The pixel width a printed `width` in `unit` implies, the resolution
    /// held. nil for a value a half-typed field can hold, and for one whose
    /// pixel count would be past `maxPixelsPerAxis`.
    func resamplingToPrintWidth(_ width: Double, in unit: PrintUnit) -> PrintSize? {
        guard let pixelWidth = PrintSize.pixelCount(width, in: unit, at: ppi.x) else { return nil }
        return settingPixels(width: pixelWidth, height: pixels.height)
    }

    /// The pixel height a printed `height` in `unit` implies, the resolution
    /// held.
    func resamplingToPrintHeight(_ height: Double, in unit: PrintUnit) -> PrintSize? {
        guard let pixelHeight = PrintSize.pixelCount(height, in: unit, at: ppi.y) else { return nil }
        return settingPixels(width: pixels.width, height: pixelHeight)
    }

    /// pixels = length × ppi, refused when the input is not a usable length
    /// or the product leaves `1...maxPixelsPerAxis`. Refusing rather than
    /// clamping keeps the conversion inside `Int`, and means an impossible
    /// print size moves nothing at all — the field then snaps back to the
    /// truth when editing ends, instead of quietly proposing a canvas the
    /// pixel fields would reject.
    private static func pixelCount(
        _ length: Double, in unit: PrintUnit, at ppi: Double
    ) -> Int? {
        guard length.isFinite, length > 0 else { return nil }
        let count = (length / unit.perInch * ppi).rounded()
        guard count >= 1, count <= Double(maxPixelsPerAxis) else { return nil }
        return Int(count)
    }

    // MARK: - Fitting a page

    /// The size to draw a `natural`-sized picture at inside `available`:
    /// scaled DOWN uniformly when it does not fit, and **never up**.
    ///
    /// Enlarging would print the picture at a resolution the document does
    /// not have, so a 4 × 6 inch photo prints 4 × 6 inches on A4 rather
    /// than growing to fill the sheet.
    static func fitted(_ natural: NSSize, within available: NSSize) -> NSSize {
        guard natural.width > 0, natural.height > 0,
              available.width > 0, available.height > 0
        else { return natural }
        let scale = min(
            1, min(available.width / natural.width, available.height / natural.height))
        return NSSize(width: natural.width * scale, height: natural.height * scale)
    }
}
