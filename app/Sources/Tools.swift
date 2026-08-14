import AppKit

/// Tools offered by the editor UI, shared by EditorViewController (menus,
/// toolbar, options bar, status) and ImageCanvasView (mouse and key
/// routing). Raw values are a stable order, not a toolbar position — the
/// toolbar groups tools into buttons (see `toolbarGroups`).
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

    /// The status bar's (and tool menu's) name for the tool.
    var displayName: String {
        switch self {
        case .select: return "Select"
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
        }
    }

    /// The toolbar's label, which has ~46pt to draw it in — so it is not
    /// always `displayName`.
    var shortLabel: String {
        switch self {
        case .select: return "Select"
        case .ellipseSelect: return "Ellipse"
        case .lasso: return "Lasso"
        case .wand: return "Wand"
        case .subject: return "Subject"
        case .move: return "Move"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .fill: return "Fill"
        case .gradient: return "Grad"
        case .text: return "Text"
        case .eyedropper: return "Pick"
        }
    }

    /// SF Symbol drawn in the toolbar and in a group's dropdown.
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
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
        }
    }

    /// Drawn in the toolbar when the symbol is unavailable.
    var fallbackGlyph: String {
        switch self {
        case .select: return "S"
        case .ellipseSelect: return "O"
        case .lasso: return "L"
        case .wand: return "W"
        // S, O, L and W are taken by the rest of this tool's toolbar
        // group, where a dropdown draws them side by side, so Subject
        // takes the next distinctive letter of its own name.
        case .subject: return "U"
        case .move: return "M"
        case .brush: return "B"
        case .eraser: return "E"
        case .fill: return "K"
        case .gradient: return "G"
        case .text: return "T"
        case .eyedropper: return "I"
        }
    }

    /// The editor action that selects this tool — sent up the responder
    /// chain by the toolbar and its dropdowns, the same selector the Tools
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
        }
    }

    /// The canvas cursor while the tool is at rest. The move tool's open
    /// hand closes mid-drag; the canvas swaps that state in itself.
    var cursor: NSCursor {
        switch self {
        case .select, .ellipseSelect, .lasso, .wand, .subject, .fill, .gradient, .brush,
            .eraser, .eyedropper:
            return .crosshair
        case .move:
            return .openHand
        case .text:
            return .iBeam
        }
    }

    /// The bare Photoshop-style key that selects the tool: the single source
    /// for both directions of the mapping.
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
        }
    }

    /// The tool a bare Photoshop-style key selects (an unmodified,
    /// lowercased character from keyDown); nil when the character selects
    /// no tool — non-tool bare keys (brush-size brackets, Quick Mask's Q)
    /// stay in the canvas's keyDown.
    init?(keyCharacter: String) {
        guard let tool = Self.allCases.first(where: { $0.keyCharacter == keyCharacter }) else {
            return nil
        }
        self = tool
    }

    // MARK: - Toolbar grouping

    /// The toolbar's buttons, left to right. A group with more than one
    /// member is ONE button: it draws whichever member is current and offers
    /// the rest under a dropdown chevron, so related tools cost one slot no
    /// matter how many join them. Every tool appears exactly once (the
    /// toolbar asserts it); grouping is the toolbar's business alone —
    /// menus, keys, the canvas and the agent all address tools directly.
    static let toolbarGroups: [[EditorTool]] = [
        [.select, .ellipseSelect, .lasso, .wand, .subject],
        [.move],
        [.brush, .eraser],
        [.fill],
        [.gradient],
        [.text],
        [.eyedropper],
    ]

    /// Index into `toolbarGroups` of the button this tool lives in.
    var toolbarGroupIndex: Int {
        Self.toolbarGroups.firstIndex { $0.contains(self) } ?? 0
    }
}
