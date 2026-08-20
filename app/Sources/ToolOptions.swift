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
    /// 0 Layer, 1 Group.
    var autoSelectIndex = 0
    var showTransformControls = true
    var snapToLayers = true
    var nudgeStep: Double = 1
}

/// Shared by the four paint tools — brush, eraser, clone, dodge — each of
/// which keeps its OWN instance, so the eraser's size never follows the
/// brush's. The dodge tool reads `opacity` as its exposure and adds the
/// burn/range pair no other paint tool shows.
struct PaintToolOptions: Codable, Equatable {
    var size: Double = 24
    var hardness: Double = 0
    var opacity: Double = 100
    var flow: Double = 100
    var blendIndex = 0
    var spacing: Double = 10
    var angle: Double = 0
    var roundness: Double = 100
    var smoothing: Double = 20
    var pressureSize = true
    var airbrush = false
    // Dodge / Burn only.
    var burn = false
    /// 0 shadows, 1 midtones, 2 highlights.
    var rangeIndex = 1
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

struct TextToolOptions: Codable, Equatable {
    var family = "Helvetica Neue"
    /// NSFontManager weight for the family (5 regular … 9 bold);
    /// the popup maps its rows onto these.
    var weight = 5
    var size: Double = 48
    var tracking: Double = 0
    /// 0 left, 1 center, 2 right.
    var alignmentIndex = 0
    var leading: Double = 0
    var baselineShift: Double = 0
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
    var fill: FillToolOptions { didSet { save(fill, "fill") } }
    var gradient: GradientToolOptions { didSet { save(gradient, "gradient") } }
    var shape: ShapeToolOptions { didSet { save(shape, "shape") } }
    var text: TextToolOptions { didSet { save(text, "text") } }
    var sample: SampleToolOptions { didSet { save(sample, "sample") } }
    var view: ViewToolOptions { didSet { save(view, "view") } }
    var sharedState: SharedToolState { didSet { save(sharedState, "shared") } }

    /// The paint-family options for a paint tool; nil for the rest.
    func paintOptions(for tool: EditorTool) -> PaintToolOptions? {
        switch tool {
        case .brush: return brush
        case .eraser: return eraser
        case .clone: return clone
        case .dodge: return dodge
        default: return nil
        }
    }

    func setPaintOptions(_ options: PaintToolOptions, for tool: EditorTool) {
        switch tool {
        case .brush: brush = options
        case .eraser: eraser = options
        case .clone: clone = options
        case .dodge: dodge = options
        default: break
        }
    }

    private init() {
        select = Self.load("select") ?? SelectToolOptions()
        crop = Self.load("crop") ?? CropToolOptions()
        move = Self.load("move") ?? MoveToolOptions()
        brush = Self.load("brush") ?? PaintToolOptions()
        eraser = Self.load("eraser") ?? PaintToolOptions()
        clone = Self.load("clone") ?? PaintToolOptions()
        dodge = Self.load("dodge") ?? PaintToolOptions(opacity: 50)
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
