import AppKit

/// Tools offered by the editor UI, shared by EditorViewController (menus,
/// rail, options bar, status) and ImageCanvasView (mouse and key routing).
/// Raw values are a stable order, not a rail position — the rail groups
/// tools into slots (see `railGroups`).
enum EditorTool: Int, CaseIterable {
    case select = 0
    case ellipseSelect
    case lasso
    case wand
    case subject
    case move
    case brush
    case eraser
    case fill
    case gradient
    case text
    case eyedropper
    case crop
    case clone
    case dodge
    // The retouching group: the two healing brushes, the Patch tool and Red
    // Eye. Appended rather than slotted beside `clone` because the raw value
    // is a stable order (a `.rz`-independent but persisted-in-defaults
    // number); the rail puts them where they belong (see `railGroups`).
    case heal
    case spotHeal
    case patch
    case redEye
    case shapeRect
    case shapeEllipse
    case shapeLine
    case zoom
    case hand

    /// The status bar's (and tool menu's) name for the tool.
    var displayName: String {
        switch self {
        case .select: return "Rectangle Select"
        case .ellipseSelect: return "Ellipse Select"
        case .lasso: return "Lasso"
        case .wand: return "Magic Wand"
        case .subject: return "Subject Select"
        case .move: return "Move"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .fill: return "Fill"
        case .gradient: return "Gradient"
        case .text: return "Text"
        case .eyedropper: return "Eyedropper"
        case .crop: return "Crop"
        case .clone: return "Clone Stamp"
        case .dodge: return "Dodge / Burn"
        case .heal: return "Healing Brush"
        case .spotHeal: return "Spot Healing Brush"
        case .patch: return "Patch"
        case .redEye: return "Red Eye"
        case .shapeRect: return "Rectangle"
        case .shapeEllipse: return "Ellipse"
        case .shapeLine: return "Line"
        case .zoom: return "Zoom"
        case .hand: return "Hand"
        }
    }

    /// SF Symbol drawn in the rail and in a group's dropdown. The design's
    /// `highlight.rectangle` and `stamp` don't resolve on macOS 15, hence
    /// the marquee-dash and clone-squares stand-ins.
    var symbol: String {
        switch self {
        case .select: return "rectangle.dashed"
        case .ellipseSelect: return "circle.dashed"
        case .lasso: return "lasso"
        case .wand: return "wand.and.stars"
        case .subject: return "person.and.background.dotted"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .fill: return "drop.fill"
        case .gradient: return "circle.lefthalf.filled"
        case .text: return "textformat"
        case .eyedropper: return "eyedropper"
        case .crop: return "crop"
        case .clone: return "square.fill.on.square"
        case .dodge: return "circle.righthalf.filled"
        case .heal: return "bandage"
        case .spotHeal: return "bandage.fill"
        case .patch: return "lasso.badge.sparkles"
        case .redEye: return "eye.trianglebadge.exclamationmark"
        case .shapeRect: return "rectangle"
        case .shapeEllipse: return "circle"
        case .shapeLine: return "line.diagonal"
        case .zoom: return "magnifyingglass"
        case .hand: return "hand.raised"
        }
    }

    /// Drawn in the rail when the symbol is unavailable.
    var fallbackGlyph: String {
        switch self {
        case .select: return "S"
        case .ellipseSelect: return "O"
        case .lasso: return "L"
        case .wand: return "W"
        // S, O, L and W are taken by the rest of this tool's rail group,
        // where a dropdown draws them side by side, so Subject takes the
        // next distinctive letter of its own name.
        case .subject: return "U"
        case .move: return "M"
        case .brush: return "B"
        case .eraser: return "E"
        case .fill: return "K"
        case .gradient: return "G"
        case .text: return "T"
        case .eyedropper: return "I"
        case .crop: return "C"
        case .clone: return "J"
        case .dodge: return "D"
        // H (Hand) and S (Rectangle Select) are taken, so the two healing
        // brushes take the next distinctive letter of their own names —
        // bAndage and spot healiNg — the way Subject took U.
        case .heal: return "A"
        case .spotHeal: return "N"
        case .patch: return "P"
        case .redEye: return "Y"
        case .shapeRect: return "R"
        case .shapeEllipse: return "E"
        case .shapeLine: return "/"
        case .zoom: return "Z"
        case .hand: return "H"
        }
    }

    /// The editor action that selects this tool — sent up the responder
    /// chain by the rail and its dropdowns, the same selector the Tools
    /// menu uses.
    var action: Selector {
        switch self {
        case .select: return #selector(EditorViewController.selectSelectTool(_:))
        case .ellipseSelect: return #selector(EditorViewController.selectEllipseTool(_:))
        case .lasso: return #selector(EditorViewController.selectLassoTool(_:))
        case .wand: return #selector(EditorViewController.selectWandTool(_:))
        case .subject: return #selector(EditorViewController.selectSubjectTool(_:))
        case .move: return #selector(EditorViewController.selectMoveTool(_:))
        case .brush: return #selector(EditorViewController.selectBrushTool(_:))
        case .eraser: return #selector(EditorViewController.selectEraserTool(_:))
        case .fill: return #selector(EditorViewController.selectFillTool(_:))
        case .gradient: return #selector(EditorViewController.selectGradientTool(_:))
        case .text: return #selector(EditorViewController.selectTextTool(_:))
        case .eyedropper: return #selector(EditorViewController.selectEyedropperTool(_:))
        case .crop: return #selector(EditorViewController.selectCropTool(_:))
        case .clone: return #selector(EditorViewController.selectCloneTool(_:))
        case .dodge: return #selector(EditorViewController.selectDodgeTool(_:))
        case .heal: return #selector(EditorViewController.selectHealTool(_:))
        case .spotHeal: return #selector(EditorViewController.selectSpotHealTool(_:))
        case .patch: return #selector(EditorViewController.selectPatchTool(_:))
        case .redEye: return #selector(EditorViewController.selectRedEyeTool(_:))
        case .shapeRect: return #selector(EditorViewController.selectShapeRectTool(_:))
        case .shapeEllipse: return #selector(EditorViewController.selectShapeEllipseTool(_:))
        case .shapeLine: return #selector(EditorViewController.selectShapeLineTool(_:))
        case .zoom: return #selector(EditorViewController.selectZoomTool(_:))
        case .hand: return #selector(EditorViewController.selectHandTool(_:))
        }
    }

    /// The canvas cursor while the tool is at rest. The move and hand
    /// tools' open hands close mid-drag; the canvas swaps that state in
    /// itself.
    var cursor: NSCursor {
        switch self {
        case .select, .ellipseSelect, .lasso, .wand, .subject, .fill, .gradient, .brush,
            .eraser, .eyedropper, .crop, .clone, .dodge, .heal, .spotHeal, .patch, .redEye,
            .shapeRect, .shapeEllipse, .shapeLine:
            return .crosshair
        case .move, .hand:
            return .openHand
        case .text:
            return .iBeam
        case .zoom:
            return Self.zoomCursor
        }
    }

    /// AppKit ships no magnifier cursor; one is built once from the zoom
    /// tool's own symbol, falling back to the crosshair if the symbol
    /// somehow fails to render.
    private static let zoomCursor: NSCursor = {
        guard let icon = NSImage(
            systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        else { return .crosshair }
        let tinted = icon.tinted(with: .black)
        return NSCursor(image: tinted, hotSpot: NSPoint(x: 6, y: 6))
    }()

    /// The bare Photoshop-style key that selects the tool: the single source
    /// for both directions of the mapping. The three shape tools share R —
    /// repeated presses cycle them (see EditorViewController.selectToolForKey).
    var keyCharacter: String {
        switch self {
        case .select: return "m"
        case .ellipseSelect: return "o"
        case .lasso: return "l"
        case .wand: return "w"
        case .subject: return "s"
        case .move: return "v"
        case .brush: return "b"
        case .eraser: return "e"
        case .fill: return "k"
        case .gradient: return "g"
        case .text: return "t"
        case .eyedropper: return "i"
        case .crop: return "c"
        case .clone: return "j"
        case .dodge: return "d"
        // Photoshop's healing slot shares one key; repeated presses cycle
        // the four, exactly as R cycles the shape tools.
        case .heal, .spotHeal, .patch, .redEye: return "p"
        case .shapeRect, .shapeEllipse, .shapeLine: return "r"
        case .zoom: return "z"
        case .hand: return "h"
        }
    }

    /// The tool a bare Photoshop-style key selects (an unmodified,
    /// lowercased character from keyDown); nil when the character selects
    /// no tool — non-tool bare keys (brush-size brackets, Quick Mask's Q)
    /// stay in the canvas's keyDown. A key shared by several tools (the
    /// shape group's R) maps to the first; cycling is the editor's business.
    init?(keyCharacter: String) {
        guard let tool = Self.allCases.first(where: { $0.keyCharacter == keyCharacter }) else {
            return nil
        }
        self = tool
    }

    /// The smallest brush this tool can do anything with, in px — the floor
    /// its Size field, its `[` key and its agent mirror all clamp to.
    ///
    /// One for every paint tool but the two healing brushes, and three for
    /// those, because `doc_heal`'s rule makes anything smaller inert: the
    /// solve keeps the destination at every covered pixel that touches an
    /// uncovered one, so the healed footprint is always the brush eroded by a
    /// pixel and a footprint one or two pixels across is entirely boundary.
    /// Confirmed against the built app: `heal_stroke` at size 1 and 2 changes
    /// nothing while 3 and 4 heal. Left un-floored, a retoucher stepping the
    /// brush down with `[` to chase a thin scratch watched the clone land for
    /// the whole drag and then vanish with a beep.
    var minimumBrushSize: Double {
        switch self {
        case .heal, .spotHeal:
            return 3
        case .brush, .eraser, .clone, .dodge, .select, .ellipseSelect, .lasso, .wand,
            .subject, .move, .fill, .gradient, .text, .eyedropper, .crop, .patch, .redEye,
            .shapeRect, .shapeEllipse, .shapeLine, .zoom, .hand:
            return 1
        }
    }

    /// True for the tools whose stroke is a BRUSH TIP: the ones the bare
    /// `[` / `]` keys resize, whose options bar carries the tip cluster, and
    /// whose paint is clipped to the active layer's extent. Lives here rather
    /// than as a `||` chain repeated in the canvas — a per-tool fact belongs
    /// on the enum. Exhaustive on purpose: a new tool must answer it.
    var usesBrushTip: Bool {
        switch self {
        case .brush, .eraser, .clone, .dodge, .heal, .spotHeal:
            return true
        case .select, .ellipseSelect, .lasso, .wand, .subject, .move, .fill, .gradient,
            .text, .eyedropper, .crop, .patch, .redEye, .shapeRect, .shapeEllipse,
            .shapeLine, .zoom, .hand:
            return false
        }
    }

    /// True while a tool's behavior hasn't landed: it stays visible in the
    /// rail and menus (with a "Soon" affordance) but validation disables it
    /// everywhere. The availability gate future tools arrive behind.
    var planned: Bool { false }

    // MARK: - Rail grouping

    /// The rail's slots, top to bottom. A group with more than one member is
    /// ONE slot: it draws whichever member is current and offers the rest
    /// under a corner-triangle dropdown, so related tools cost one slot no
    /// matter how many join them. Every tool appears exactly once (the rail
    /// asserts it); grouping is the rail's business alone — menus, keys,
    /// the canvas and the agent all address tools directly.
    static let railGroups: [[EditorTool]] = [
        [.select, .ellipseSelect, .lasso, .wand, .subject],
        [.crop],
        [.move],
        [.brush, .eraser, .clone, .dodge],
        // Photoshop's own healing slot, immediately below the paint group.
        [.spotHeal, .heal, .patch, .redEye],
        [.fill],
        [.gradient],
        [.shapeRect, .shapeEllipse, .shapeLine],
        [.text],
        [.eyedropper],
        [.zoom, .hand],
    ]

    /// Index into `railGroups` of the slot this tool lives in.
    var railGroupIndex: Int {
        Self.railGroups.firstIndex { $0.contains(self) } ?? 0
    }
}
