import AppKit

// Per-tool option values, persisted across documents and launches so a tool
// comes back with the settings it was last used with — the same memory the
// rail keeps for group members. One Codable value type per tool family; the
// options bar's descriptors read and write these through ToolOptionsStore.
//
// A field being stored does NOT mean the app honors it yet: the options bar
// deliberately carries the full option set from the redesign, with the
// unbacked ones validation-disabled, so future support is a wiring change
// rather than a layout change.

struct SelectToolOptions: Codable, Equatable {
    /// Combine mode for new selection gestures (0 new, 1 add, 2 subtract,
    /// 3 intersect); the Shift/Option modifiers still override per gesture.
    var modeIndex = 0
    /// Feather radius applied to selections as the gesture commits.
    var feather: Double = 0
    var antiAlias = true
    /// Amounts the overflow popover's morphology fields apply with.
    var growAmount: Double = 8
    var borderWidth: Double = 2
    var smoothRadius: Double = 4
    // Magic Wand.
    var tolerance: Double = 32
    var contiguous = true
    var sampleAllLayers = false
}

struct CropToolOptions: Codable, Equatable {
    /// Index into EditorViewController.cropRatios.
    var ratioIndex = 0
    var deleteCroppedPixels = false
    /// 0 none, 1 thirds.
    var gridIndex = 1
    var contentAwareFill = false
    var snapToGuides = true
}

struct MoveToolOptions: Codable, Equatable {
    /// Whether a Move click activates the entry under the cursor at all.
    /// Off by default, like Photoshop's: with it on, a click anywhere on the
    /// canvas retargets every later edit, which is surprising until it is
    /// asked for.
    var autoSelect = false
    /// What Auto-Select picks: 0 the LAYER under the cursor, 1 its top-level
    /// GROUP.
    var autoSelectIndex = 0
    var showTransformControls = true
    var snapToLayers = true
    var nudgeStep: Double = 1
}

/// Shared by the six paint tools — brush, eraser, clone, dodge and the two
/// healing brushes — each of which keeps its OWN instance, so the eraser's
/// size never follows the brush's. The dodge tool reads `opacity` as its
/// exposure and adds the burn/range pair no other paint tool shows; the
/// healing brushes read `opacity` as the heal's strength and add the
/// aligned/sample pair below.
///
/// Adding a field resets every saved blob of this family once (the
/// synthesized decoder throws on the first missing key and
/// `ToolOptionsStore.load` falls back to defaults) — what every earlier
/// addition here did. `TextToolOptions` buys its way out with a hand-written
/// all-optional decoder; this family stays synthesized, because a
/// hand-written one silently reads a LATER forgotten field as its default
/// instead of resetting loudly once.
struct PaintToolOptions: Codable, Equatable {
    var size: Double = 24
    /// 100 = the classic hard round; below that, SoftBrush dab stamping.
    var hardness: Double = 100
    var opacity: Double = 100
    /// Per-dab deposit; opacity still caps the whole stroke once.
    var flow: Double = 100
    /// The stroke's blend mode as a RAW RzBlendMode value (stable across
    /// releases; 0 = Normal). Honored by brush and clone only.
    var blendIndex = 0
    /// Dab spacing as % of the diameter; 25 is the classic rhythm (and
    /// keeps the smoother hard-path pipeline at hardness 100).
    var spacing: Double = 25
    var angle: Double = 0
    var roundness: Double = 100
    /// Pulled-string stabilization; 0 turns the leash off.
    var smoothing: Double = 20
    var pressureSize = true
    var airbrush = false
    // Dodge / Burn only.
    var burn = false
    /// 0 shadows, 1 midtones, 2 highlights.
    var rangeIndex = 1
    // Healing Brush only (the two above are Dodge / Burn only the same way).
    /// The sampled source offset set by the first stroke after the source
    /// point was placed PERSISTS across strokes; off, every mouse-down
    /// recomputes it from the source point — today's Clone Stamp rule. While
    /// it is on, the canvas's source marker tracks the pointer rather than
    /// the ⌥-clicked point, because the offset is what persists and the
    /// point being sampled therefore moves (`ImageCanvasView`'s
    /// `cloneSourceMarkerPoint`).
    var aligned = true
    /// Heal from the flattened composite instead of the layer's own pixels.
    /// The Healing Brush honors it Swift-side (it picks the snapshot the
    /// stroke stamps); the Spot Healing Brush passes it to the core, which
    /// has to generate the source and so must know.
    var sampleAllLayers = true
    /// nil in blobs saved before the tip options went live — those carry
    /// the redesign's DISABLED placeholder values (spacing 10), which no
    /// user could have chosen and the pipeline never honored. Decoding nil
    /// normalizes them to the live defaults (see ToolOptionsStore.load);
    /// 1 marks a blob whose tip values are real choices.
    var tipVersion: Int?

    /// A pre-tip blob's placeholders replaced by the live defaults, so an
    /// upgrade renders every stroke exactly as the previous release did
    /// (spacing 10 would otherwise walk soft dabs 2.5x denser than the
    /// classic quarter-diameter rhythm the old pipeline hardcoded).
    var migratedToLiveTip: PaintToolOptions {
        guard tipVersion == nil else { return self }
        var out = self
        out.spacing = 25
        out.tipVersion = 1
        return out
    }
}

/// The Patch tool: which way the drag runs, and where the texture comes
/// from. No tip options — the footprint is an outlined region, not a brush.
struct PatchToolOptions: Codable, Equatable {
    /// 0 Source (the default, Photoshop's): the OUTLINED region is healed
    /// from wherever it is dragged to. 1 Destination: the outlined region is
    /// good texture, dragged onto the flaw.
    var directionIndex = 0
    var sampleAllLayers = true
}

/// The Red Eye tool's two dials, both percentages.
struct RedEyeToolOptions: Codable, Equatable {
    /// Rejects a red region whose larger side exceeds this fraction of the
    /// drag rectangle's SHORTER side. 100 — permissive — is deliberate: the
    /// gesture the app documents is a tight rectangle over one eye, where
    /// the red iris spans 40–90 % of the short side, so a smaller default
    /// would refuse the tool's own instruction. Turn it down when something
    /// red (a shirt, lipstick) got caught by a sloppy rectangle.
    var pupilSize: Double = 100
    /// How far the corrected pupil darkens after the red is neutralised;
    /// 50 is Photoshop's default, 0 neutralises only.
    var darken: Double = 50
}

/// Content-Aware Fill's sheet values, persisted like a tool's options: the
/// command has no tool of its own to hang them on.
struct ContentAwareFillOptions: Codable, Equatable {
    /// Sampling-ring width in px around the selection (21–512; the core's own
    /// floor is three patch widths and it raises anything below it).
    var ring: Double = 48
    var sampleAllLayers = false
    /// The inpaint's RNG seed: the same seed refills identically.
    var seed = 0
}

struct FillToolOptions: Codable, Equatable {
    /// 0 Foreground.
    var contentsIndex = 0
    var tolerance: Double = 32
    var contiguous = true
    var opacity: Double = 100
    var blendIndex = 0
    var sampleAllLayers = false
    var antiAlias = true
}

struct GradientToolOptions: Codable, Equatable {
    /// 0 linear, 1 radial (2 angle, 3 reflected, 4 diamond are planned).
    var typeIndex = 0
    var opacity: Double = 100
    var reverse = false
    var dither = true
    var midpoint: Double = 50
    /// 0 Perceptual.
    var methodIndex = 0
}

struct ShapeToolOptions: Codable, Equatable {
    /// "#RRGGBBAA", or "" for none — ShapeLayerPayload's convention.
    var fill = "#C96F4AFF"
    var stroke = "#E8E2D4FF"
    var strokeWidth: Double = 2
    var radius: Double = 8
    /// 0 New layer.
    var pathOpIndex = 0
}

/// The text tool's typography. Every field is what `TextStyle` (TextLayer.swift)
/// renders with, so a value here is exactly what the next commit writes into
/// the layer's description; `EditorViewController.currentTextStyle()` reads
/// them and `applyTextOptions` writes a reopened layer's back.
struct TextToolOptions: Codable, Equatable {
    var family = "Helvetica Neue"
    /// NSFontManager weight for the family (0…15: 3 light, 5 regular,
    /// 6 medium, 8 semibold, 9 bold); the popup maps its rows onto these.
    var weight = 5
    var size: Double = 48
    /// Extra spacing between glyphs in px (the `.kern` attribute, so it
    /// changes line breaks); 0 = the font's own spacing, negative tightens.
    var tracking: Double = 0
    /// 0 left, 1 center, 2 right.
    var alignmentIndex = 0
    /// Line height in pt, baseline to baseline: 0 = the font's natural
    /// height, otherwise every line is pinned to exactly this height
    /// (`TextStyle.leading` — the options bar's "Leading … pt" field).
    var leading: Double = 0
    /// Baseline shift in px; positive raises the glyphs (`.baselineOffset`).
    var baselineShift: Double = 0
    var italic = false
    var underline = false
    var strikethrough = false

    /// Spelled out so the key names stay the property names a blob saved
    /// before the three toggles existed was written with.
    enum CodingKeys: String, CodingKey {
        case family, weight, size, tracking, alignmentIndex, leading, baselineShift
        case italic, underline, strikethrough
    }

    /// The options bar's ranges for the numeric typography — the ONE home
    /// the bar's fields, the agent's `weight` / `tracking` / `leading` /
    /// `baseline_shift` arguments and the restore of a reopened layer's
    /// description all read, so agent and UI accept the same values and the
    /// store never holds one the bar cannot express.
    static let weightRange = 0...15
    static let trackingRange: ClosedRange<Double> = -100...100
    static let leadingRange: ClosedRange<Double> = 0...1000
    static let baselineShiftRange: ClosedRange<Double> = -100...100

    /// The typography clamped into those ranges, a non-finite number
    /// falling back to its default. `applyTextOptions` stores a reopened
    /// layer's description through this: `TextLayerPayload.decode` accepts
    /// any finite tracking, leading or shift, and a `.rz` from elsewhere
    /// can carry one the bar cannot express — left in the store it would
    /// type every NEW session with it (a tracking of a million lays each
    /// glyph on its own line and pushes the commit past the pixel cap)
    /// until the field was reset by hand. `currentTextStyle` reads the
    /// store through it too, so a hand-edited defaults blob is bounded the
    /// same way. The reopened SESSION itself still previews the layer's own
    /// values (`canvas.textStyle`), so what it shows is what the layer
    /// renders and an unchanged ⌘Return registers no edit.
    func clampingTypography() -> TextToolOptions {
        var clamped = self
        clamped.weight = min(max(weight, Self.weightRange.lowerBound), Self.weightRange.upperBound)
        clamped.tracking = Self.clamp(tracking, to: Self.trackingRange, default: 0)
        clamped.leading = Self.clamp(leading, to: Self.leadingRange, default: 0)
        clamped.baselineShift = Self.clamp(baselineShift, to: Self.baselineShiftRange, default: 0)
        return clamped
    }

    private static func clamp(
        _ value: Double, to range: ClosedRange<Double>, default fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

extension TextToolOptions {
    /// Every key optional, so a blob saved before a field existed keeps the
    /// user's family, size and weight: the synthesized decoder throws on the
    /// first missing key and `ToolOptionsStore.load` would then drop the
    /// whole blob back to defaults (which is what every earlier field
    /// addition did). Declared in an extension so the struct keeps its
    /// implicit `init()`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TextToolOptions()
        family = try container.decodeIfPresent(String.self, forKey: .family) ?? defaults.family
        weight = try container.decodeIfPresent(Int.self, forKey: .weight) ?? defaults.weight
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? defaults.size
        tracking = try container.decodeIfPresent(Double.self, forKey: .tracking)
            ?? defaults.tracking
        alignmentIndex = try container.decodeIfPresent(Int.self, forKey: .alignmentIndex)
            ?? defaults.alignmentIndex
        leading = try container.decodeIfPresent(Double.self, forKey: .leading) ?? defaults.leading
        baselineShift = try container.decodeIfPresent(Double.self, forKey: .baselineShift)
            ?? defaults.baselineShift
        italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? defaults.italic
        underline = try container.decodeIfPresent(Bool.self, forKey: .underline)
            ?? defaults.underline
        strikethrough = try container.decodeIfPresent(Bool.self, forKey: .strikethrough)
            ?? defaults.strikethrough
    }
}

struct SampleToolOptions: Codable, Equatable {
    /// 0 point, 1 3×3, 2 5×5.
    var sampleSizeIndex = 0
    /// 0 current layer, 1 all layers.
    var fromIndex = 1
    var showRing = true
    var copyOnPick = false
}

struct ViewToolOptions: Codable, Equatable {
    var scrubbyZoom = false
    var rulers = false
    var guides = true
    /// 0 auto, 1 on, 2 off.
    var pixelGridIndex = 0
}

/// Cross-tool state that is nobody's option in particular: the rail's two
/// color swatches ("#RRGGBBAA", TextLayer's hex convention).
struct SharedToolState: Codable, Equatable {
    var foreground = "#000000FF"
    var background = "#FFFFFFFF"
}

/// The persistence point: one property per family (paint tools get one
/// each), loaded from UserDefaults at startup and written back on every
/// change. Shared across editor windows deliberately — tool options follow
/// the user, not the document.
final class ToolOptionsStore {
    static let shared = ToolOptionsStore()

    var select: SelectToolOptions { didSet { save(select, "select") } }
    var crop: CropToolOptions { didSet { save(crop, "crop") } }
    var move: MoveToolOptions { didSet { save(move, "move") } }
    var brush: PaintToolOptions { didSet { save(brush, "brush") } }
    var eraser: PaintToolOptions { didSet { save(eraser, "eraser") } }
    var clone: PaintToolOptions { didSet { save(clone, "clone") } }
    var dodge: PaintToolOptions { didSet { save(dodge, "dodge") } }
    var heal: PaintToolOptions { didSet { save(heal, "heal") } }
    var spotHeal: PaintToolOptions { didSet { save(spotHeal, "spotHeal") } }
    var patch: PatchToolOptions { didSet { save(patch, "patch") } }
    var redEye: RedEyeToolOptions { didSet { save(redEye, "redEye") } }
    var contentAwareFill: ContentAwareFillOptions {
        didSet { save(contentAwareFill, "contentAwareFill") }
    }
    var fill: FillToolOptions { didSet { save(fill, "fill") } }
    var gradient: GradientToolOptions { didSet { save(gradient, "gradient") } }
    var shape: ShapeToolOptions { didSet { save(shape, "shape") } }
    var text: TextToolOptions { didSet { save(text, "text") } }
    var sample: SampleToolOptions { didSet { save(sample, "sample") } }
    var view: ViewToolOptions { didSet { save(view, "view") } }
    var sharedState: SharedToolState { didSet { save(sharedState, "shared") } }

    /// The paint-family options for a paint tool; nil for the rest.
    ///
    /// Size is floored at the tool's own minimum on the way out AND on the way
    /// in (`EditorTool.minimumBrushSize` — three for the healing brushes,
    /// whose solve can do nothing with a footprint two pixels across). Both
    /// directions, because this is the one read every caller shares — the
    /// options bar, the canvas sync and the `[` key's read-modify-write — and
    /// a blob saved by an earlier build can hold anything.
    func paintOptions(for tool: EditorTool) -> PaintToolOptions? {
        var options: PaintToolOptions
        switch tool {
        case .brush: options = brush
        case .eraser: options = eraser
        case .clone: options = clone
        case .dodge: options = dodge
        case .heal: options = heal
        case .spotHeal: options = spotHeal
        default: return nil
        }
        options.size = max(options.size, tool.minimumBrushSize)
        return options
    }

    func setPaintOptions(_ options: PaintToolOptions, for tool: EditorTool) {
        var options = options
        options.size = max(options.size, tool.minimumBrushSize)
        switch tool {
        case .brush: brush = options
        case .eraser: eraser = options
        case .clone: clone = options
        case .dodge: dodge = options
        case .heal: heal = options
        case .spotHeal: spotHeal = options
        default: break
        }
    }

    private init() {
        select = Self.load("select") ?? SelectToolOptions()
        crop = Self.load("crop") ?? CropToolOptions()
        move = Self.load("move") ?? MoveToolOptions()
        brush = (Self.load("brush") ?? PaintToolOptions()).migratedToLiveTip
        eraser = (Self.load("eraser") ?? PaintToolOptions()).migratedToLiveTip
        clone = (Self.load("clone") ?? PaintToolOptions()).migratedToLiveTip
        dodge = (Self.load("dodge") ?? PaintToolOptions(opacity: 50)).migratedToLiveTip
        heal = (Self.load("heal") ?? PaintToolOptions()).migratedToLiveTip
        // Spot healing generates its own source from the layer it is used on;
        // sampling the composite there would inpaint from pixels the layer
        // does not own (§0.5), so its default is off — the one difference.
        spotHeal = (Self.load("spotHeal") ?? PaintToolOptions(sampleAllLayers: false))
            .migratedToLiveTip
        patch = Self.load("patch") ?? PatchToolOptions()
        redEye = Self.load("redEye") ?? RedEyeToolOptions()
        contentAwareFill = Self.load("contentAwareFill") ?? ContentAwareFillOptions()
        fill = Self.load("fill") ?? FillToolOptions()
        gradient = Self.load("gradient") ?? GradientToolOptions()
        shape = Self.load("shape") ?? ShapeToolOptions()
        text = Self.load("text") ?? TextToolOptions()
        sample = Self.load("sample") ?? SampleToolOptions()
        view = Self.load("view") ?? ViewToolOptions()
        sharedState = Self.load("shared") ?? SharedToolState()
    }

    private static func key(_ name: String) -> String { "toolOptions.\(name)" }

    /// nil on a missing key OR an undecodable blob (a field's meaning
    /// changed): options fall back to defaults rather than error.
    private static func load<T: Decodable>(_ name: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(name))
    }
}
