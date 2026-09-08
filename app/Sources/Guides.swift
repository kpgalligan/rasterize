import AppKit

// The pure value types behind the rulers, the guides, the grid and the
// snapping chrome: a guide as the canvas sees it, the ONE bundle of view
// preferences the controller pushes into the canvas, the ruler unit and its
// conversions, the guide colour table and the ruler's tick ladder.
//
// Nothing here reads a document or touches AppKit geometry beyond colours
// and a font: it is the TextLayer / LayerTransform / SoftBrush pattern —
// value types plus math, so the drawing files and the snapping engine share
// one conversion instead of three.
//
// WHAT IS DOCUMENT STATE AND WHAT IS A PREFERENCE. Only the guide LIST and
// the ruler ORIGIN live in the core (`RzDocument.guides`, `ruler_origin`,
// `.rz` version 8): they are per-document geometry that has to survive
// save/reopen and undo, on the same shelf as alpha channels. Everything in
// this file that is *settable* — ruler visibility and unit, guide
// visibility, the guide LOCK, the guide colour, the grid and its spacing,
// the pixel-grid mode, the snap toggles, the nudge step — is an app
// PREFERENCE in `ToolOptionsStore.shared.view` (and `.crop` / `.move`),
// because `ToolOptionsStore`'s own doc says what it is for: "Shared across
// editor windows deliberately — tool options follow the user, not the
// document." A ruler unit or a snap toggle describes how this USER works,
// not what the file contains, and putting one in `.rz` would make a
// document arrive and silently change the app's behaviour.

// MARK: - A guide, as the canvas holds it

/// One guide in canvas coordinates — the Swift twin of
/// `RasterDocument.GuideInfo`, cached on the canvas so a redraw and a hit
/// test cross the FFI boundary not at all.
///
/// `position` is a GRID-LINE coordinate in the continuous canvas space, not
/// a pixel index: a vertical guide at x = 0 lies on the left canvas edge and
/// one at x = width on the right. That is the core's convention too
/// (`doc_guide.rs`), and it is why both ends of the range are legal.
struct CanvasGuide: Equatable {
    /// The core's stable identity, which is what a drag holds on to: the
    /// list re-sorts by position on every edit, so an index cannot name a
    /// guide across one.
    let id: UInt64
    let orientation: GuideOrientation
    let position: CGFloat

    init(id: UInt64, orientation: GuideOrientation, position: CGFloat) {
        self.id = id
        self.orientation = orientation
        self.position = position
    }

    init(_ info: RasterDocument.GuideInfo) {
        self.init(
            id: info.id, orientation: info.orientation, position: CGFloat(info.position))
    }

    /// The guide's line across a canvas of `size`, in canvas coordinates.
    func segment(in size: CGSize) -> (from: CGPoint, to: CGPoint) {
        switch orientation {
        case .vertical:
            return (CGPoint(x: position, y: 0), CGPoint(x: position, y: size.height))
        case .horizontal:
            return (CGPoint(x: 0, y: position), CGPoint(x: size.width, y: position))
        }
    }

    /// Two positions closer than this are the SAME line to the core, which
    /// quantizes every guide position to four decimals — so this is half of
    /// that quantum, and a comparison at it answers exactly what
    /// `doc_guide::guide_at` will. (Not `SnapEngine.epsilon`: that is a
    /// hundredth of a canvas pixel, a tie threshold for "can anyone see the
    /// difference", which is a different and much coarser question.)
    static let positionEpsilon: CGFloat = 0.00005

    /// The snap-engine line this guide contributes.
    var snapLine: SnapLine {
        SnapLine(
            axis: orientation == .vertical ? .vertical : .horizontal,
            position: position, kind: .guide)
    }
}

// MARK: - What the controller pushes into the canvas

/// The ONE value `EditorViewController.syncCanvasPaintState()` pushes into
/// `ImageCanvasView` for all of this phase's chrome.
///
/// It is one struct rather than nine stored properties for a stated reason:
/// `app/CLAUDE.md` sends anything past ~50 lines out of a frozen file, and
/// stored properties and closure declarations are the two things an
/// extension file cannot hold. Nine separate properties plus their nine
/// assignments in `syncCanvasPaintState()` would spend that whole budget on
/// bookkeeping. One value type means the frozen file gains ONE property and
/// ONE assignment, and a tenth setting later costs zero frozen lines. It is
/// a plain struct with defaults, so `ImageCanvasView` still never reads
/// `ToolOptionsStore` itself.
struct CanvasChromeSettings: Equatable {
    var guidesVisible = true
    var guidesLocked = false
    var guideColor: GuideColor = .cyan
    var showGrid = false
    /// Major grid spacing in CANVAS PIXELS per axis, converted from the
    /// ruler unit; 0 means "no usable grid" (a spacing that came out
    /// non-finite or non-positive).
    var gridSpacingX: CGFloat = 0
    var gridSpacingY: CGFloat = 0
    var gridSubdivisions = 4
    /// 0 auto, 1 on, 2 off — the stored meaning of `view.pixelGridIndex`.
    var pixelGridMode = 0
    /// The Move tool's arrow-key step in canvas pixels (Shift multiplies by
    /// ten), pushed in rather than read from the store: the canvas may not
    /// reach `ToolOptionsStore`.
    var moveNudgeStep = 1

    init() {}

    /// The preferences resolved against ONE document: the grid's spacing is
    /// authored in the ruler's unit (Photoshop's rule), so it converts here,
    /// per axis, through the same table the rulers label with.
    init(
        from store: ToolOptionsStore, unit: CanvasUnit, ppi: (x: Double, y: Double),
        canvas: CGSize
    ) {
        let view = store.view
        guidesVisible = view.guides
        guidesLocked = view.guidesLocked
        guideColor = GuideColor(rawValue: view.guideColorIndex) ?? .cyan
        showGrid = view.showGrid
        gridSubdivisions = max(1, view.gridSubdivisions)
        pixelGridMode = min(max(view.pixelGridIndex, 0), 2)
        moveNudgeStep = Int(min(max(store.move.nudgeStep, 1), 100).rounded())
        let spacing = view.gridSpacing
        guard spacing.isFinite, spacing > 0 else { return }
        let perUnitX = unit.pixelsPerUnit(axis: .vertical, ppi: ppi, canvas: canvas)
        let perUnitY = unit.pixelsPerUnit(axis: .horizontal, ppi: ppi, canvas: canvas)
        gridSpacingX = CGFloat(max(spacing * perUnitX, 0))
        gridSpacingY = CGFloat(max(spacing * perUnitY, 0))
    }

    /// The step SNAPPING and the subdivision lines use — the major spacing
    /// divided by the subdivision count, which is a superset of the major
    /// lines (Photoshop's behaviour). nil when the grid is off or degenerate.
    var gridStepX: CGFloat? { Self.step(gridSpacingX, gridSubdivisions) }
    var gridStepY: CGFloat? { Self.step(gridSpacingY, gridSubdivisions) }

    /// The MAJOR spacing as a ladder of its own — the heavy lines
    /// `drawDocumentGrid` paints. The snap engine takes both and picks the
    /// finest one that is still separable at the current zoom, so a grid
    /// whose subdivisions have become a blur still snaps on its majors.
    var gridMajorX: CGFloat? { Self.step(gridSpacingX, 1) }
    var gridMajorY: CGFloat? { Self.step(gridSpacingY, 1) }

    private static func step(_ spacing: CGFloat, _ subdivisions: Int) -> CGFloat? {
        guard spacing.isFinite, spacing > 0 else { return nil }
        let step = spacing / CGFloat(max(1, subdivisions))
        return step.isFinite && step > 0 ? step : nil
    }
}

/// The grid's menu presets. One home, so View ▸ Grid Spacing and View ▸
/// Grid Subdivisions cannot drift from the values the store accepts.
enum CanvasGrid {
    /// In the RULER's current unit, so 100 with the default Pixels unit is a
    /// 100 px grid — the sensible twin of Photoshop's 1 inch.
    static let spacingPresets: [Double] = [8, 10, 16, 20, 25, 50, 100, 200]
    static let subdivisionPresets: [Int] = [1, 2, 4, 5, 10]
}

// MARK: - Units

/// The six units a ruler, the grid and the New Guide sheet speak. Exactly
/// the brief's list; deliberately no picas, which nothing else in the app
/// measures in.
///
/// This is the ONE conversion between canvas pixels and a displayed length:
/// the two ruler strips, the grid's spacing, the New Guide sheet's field and
/// any future readout all come here.
enum CanvasUnit: Int, CaseIterable {
    case pixels
    case inches
    case centimeters
    case millimeters
    case points
    case percent

    var displayName: String {
        switch self {
        case .pixels: return "Pixels"
        case .inches: return "Inches"
        case .centimeters: return "Centimeters"
        case .millimeters: return "Millimeters"
        case .points: return "Points"
        case .percent: return "Percent"
        }
    }

    var abbreviation: String {
        switch self {
        case .pixels: return "px"
        case .inches: return "in"
        case .centimeters: return "cm"
        case .millimeters: return "mm"
        case .points: return "pt"
        case .percent: return "%"
        }
    }

    /// How many canvas PIXELS make one of this unit, on one axis.
    ///
    /// Per axis on purpose: a document really can be anisotropic — the
    /// agent's `set_resolution` takes two numbers and a quarter turn swaps
    /// them (`PrintSize.resolutionText` exists for exactly that reason) — so
    /// the horizontal strip divides by `ppi.x` and the vertical by `ppi.y`.
    /// Percent is deliberately different per axis too, which is what
    /// Photoshop does and what makes a "10 %" grid ten columns by ten rows.
    ///
    /// `ppi` must already be sanitized per axis with `PrintSize.sane`, the
    /// ONE sanitizer on this side; 2.54 comes from
    /// `PrintUnit.centimetres.perInch` and 72 from `PrintSize.pointsPerInch`,
    /// the ONE copies of both constants.
    func pixelsPerUnit(axis: SnapAxis, ppi: (x: Double, y: Double), canvas: CGSize) -> Double {
        // A vertical line is a constant-X line, so it is measured along X.
        let dpi = axis == .vertical ? ppi.x : ppi.y
        let extent = Double(axis == .vertical ? canvas.width : canvas.height)
        switch self {
        case .pixels: return 1
        case .inches: return dpi
        case .centimeters: return dpi / PrintUnit.centimetres.perInch
        case .millimeters: return dpi / (PrintUnit.centimetres.perInch * 10)
        case .points: return dpi / PrintSize.pointsPerInch
        case .percent: return max(extent, 1) / 100
        }
    }

    /// A canvas coordinate as a number on the ruler: measured FROM THE RULER
    /// ORIGIN, which is the one place the origin has any effect at all (it
    /// moves labels and this sheet's typed number, never the grid, never a
    /// snap target, never an MCP coordinate).
    func value(canvas coordinate: CGFloat, origin: CGFloat, pixelsPerUnit: Double) -> Double {
        guard pixelsPerUnit.isFinite, pixelsPerUnit > 0 else { return 0 }
        return Double(coordinate - origin) / pixelsPerUnit
    }

    /// The inverse: a number read off a ruler, back in canvas coordinates.
    func canvas(value: Double, origin: CGFloat, pixelsPerUnit: Double) -> CGFloat {
        guard pixelsPerUnit.isFinite, pixelsPerUnit > 0, value.isFinite else { return origin }
        return origin + CGFloat(value * pixelsPerUnit)
    }

    /// A ruler label, with just enough decimals for the tick spacing it sits
    /// on: at a 0.25 in step "1.25", at a 100 px step "1200". Trailing zeros
    /// are trimmed so a whole number never reads "12.00".
    ///
    /// The decimal count is the smallest that writes THE STEP exactly, found
    /// by trying each in turn, and not `ceil(-log10(step))`: that formula
    /// gives 0.25 one decimal, so an inch ruler at a quarter-inch step would
    /// label its ticks 0, 0.2, 0.5, 0.8, 1 — three of the five numbers wrong,
    /// and wrong in a way that reads as a measurement rather than as
    /// rounding. Every label is a whole multiple of the step, so a count that
    /// writes the step exactly writes all of them exactly. Four is the
    /// ceiling, and both tick ladders floor their step at 10⁻⁴ / 2⁻⁴ so it is
    /// never reached from below.
    func label(_ value: Double, step: Double) -> String {
        guard value.isFinite else { return "" }
        var decimals = 0
        if step.isFinite, step > 0, step < 1 {
            while decimals < RulerTicks.maxDecimals {
                let scaled = step * pow(10, Double(decimals))
                if abs(scaled - scaled.rounded()) < 1e-9 { break }
                decimals += 1
            }
        }
        var text = String(format: "%.\(decimals)f", value)
        if decimals > 0, text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        // "-0" is a rounding artefact, never a coordinate.
        if text == "-0" { text = "0" }
        return text
    }
}

// MARK: - Guide colour

/// The six guide colours Photoshop offers, as a preference index. Coral is
/// deliberately absent: it is reserved for the selection marquee, "the app's
/// one accent-colored canvas element" (`Theme.swift`), and a guide sharing
/// it would be unreadable against a live marquee.
enum GuideColor: Int, CaseIterable {
    case cyan
    case lightBlue
    case lightRed
    case green
    case magenta
    case yellow

    var displayName: String {
        switch self {
        case .cyan: return "Cyan"
        case .lightBlue: return "Light Blue"
        case .lightRed: return "Light Red"
        case .green: return "Green"
        case .magenta: return "Magenta"
        case .yellow: return "Yellow"
        }
    }

    /// Fixed sRGB inks rather than DS tokens: a guide must read the same in
    /// both appearances and against any photograph, and the user picked the
    /// colour by name.
    var color: NSColor {
        switch self {
        case .cyan: return NSColor(srgbRed: 0, green: 0.78, blue: 0.94, alpha: 1)
        case .lightBlue: return NSColor(srgbRed: 0.40, green: 0.60, blue: 1, alpha: 1)
        case .lightRed: return NSColor(srgbRed: 1, green: 0.40, blue: 0.40, alpha: 1)
        case .green: return NSColor(srgbRed: 0, green: 0.78, blue: 0.31, alpha: 1)
        case .magenta: return NSColor(srgbRed: 1, green: 0.24, blue: 0.90, alpha: 1)
        case .yellow: return NSColor(srgbRed: 1, green: 0.78, blue: 0, alpha: 1)
        }
    }

    /// Smart guides draw in the guide colour's ACCENT — a fixed contrasting
    /// partner, one line per case, so "the guide colour's accent" is a
    /// lookup and not a colour-space computation that could land back on the
    /// guide's own hue.
    var smartColor: NSColor {
        switch self {
        case .cyan: return GuideColor.magenta.color
        case .lightBlue: return GuideColor.magenta.color
        case .lightRed: return GuideColor.cyan.color
        case .green: return GuideColor.magenta.color
        case .magenta: return GuideColor.cyan.color
        case .yellow: return GuideColor.magenta.color
        }
    }
}

// MARK: - The ruler's tick ladder

/// The ruler tick schedule: how far apart the labelled ticks are, and how
/// many minor divisions sit between two of them, at one zoom in one unit.
///
/// A pure function so both strips — and any future readout — share one
/// ladder and can never disagree about what "the next tick" is.
enum RulerTicks {
    /// The label pitch floor, in SCREEN POINTS: no two labelled ticks are
    /// closer together than this. 56 pt is "10000" set in `DS.mono(9)` plus
    /// a comfortable margin, which is the widest label a 20000 px canvas can
    /// produce; below it the numerals collide and the strip becomes noise.
    static let labelPitch: Double = 56

    /// The hard ceiling on ticks drawn per strip per redraw. A degenerate
    /// magnification or a nonsense pixels-per-unit cannot then spin the
    /// draw loop; 2000 is far more ticks than a 5000 pt wide strip can show
    /// at the minimum 2 pt spacing.
    static let maxTicks = 2000

    /// The most decimals a label may carry, and therefore the finest step
    /// either ladder may choose: 10⁻⁴ on the decimal one, 2⁻⁴ (a sixteenth
    /// of an inch) on the binary one. A step finer than its label can write
    /// is the one failure a ruler must not have — the ticks would be exact
    /// and the numbers beside them rounded — and both floors sit far below
    /// anything the app's zoom range and the core's 1…30000 ppi clamp can
    /// ask for. Past the floor the step simply stops shrinking, which only
    /// spaces the labels FURTHER apart than the pitch floor demands, and
    /// that is always safe.
    static let maxDecimals = 4

    /// `unitsPerPoint` is how much of the unit one SCREEN POINT covers —
    /// `1 / (magnification * pixelsPerUnit)`.
    static func schedule(unitsPerPoint: Double, unit: CanvasUnit)
        -> (step: Double, minorDivisions: Int)
    {
        let raw = labelPitch * unitsPerPoint
        guard raw.isFinite, raw > 0 else { return (1, 1) }
        // An inch is not decimal: it halves and doubles, so its ladder is
        // binary (… 1/8, 1/4, 1/2, 1, 2, 4 …) and a decimal one would label
        // 0.2 in, which no ruler in the world does.
        return unit == .inches ? binary(raw) : decimal(raw)
    }

    /// The 1–2–5 ladder × 10ⁿ, the one every decimal ruler uses.
    private static func decimal(_ raw: Double) -> (step: Double, minorDivisions: Int) {
        let exponent = floor(log10(raw))
        // Floored at 10⁻⁴ so every label is exact (see `maxDecimals`), and
        // ceilinged at 10¹² so a degenerate zoom cannot hand `pow` an
        // infinity the draw loop would then iterate over.
        let clamped = min(max(exponent, Double(-RulerTicks.maxDecimals)), 12)
        let decade = pow(10.0, clamped)
        let base = raw / decade
        let (multiple, divisions): (Double, Int)
        switch base {
        case ..<1.0001: (multiple, divisions) = (1, 10)
        case ..<2.0001: (multiple, divisions) = (2, 5)
        case ..<5.0001: (multiple, divisions) = (5, 5)
        default: (multiple, divisions) = (10, 10)
        }
        return (multiple * decade, divisions)
    }

    /// … 1/16, 1/8, 1/4, 1/2, 1, 2, 4, 8 … A whole number of inches divides
    /// into eighths (the familiar rule); a fraction of an inch divides in
    /// half, because eighths of an eighth are invisible.
    ///
    /// Floored at 2⁻⁴ = 1/16 in, the finest step four decimals can write
    /// exactly (0.0625) — see `maxDecimals`. Deeper zooms keep that step and
    /// simply space its labels further apart.
    private static func binary(_ raw: Double) -> (step: Double, minorDivisions: Int) {
        let exponent = min(max(ceil(log2(raw)), Double(-RulerTicks.maxDecimals)), 12)
        let step = pow(2.0, exponent)
        return (step, step >= 1 ? 8 : 2)
    }
}
