import AppKit

/// Tools offered by the editor UI, shared by EditorViewController (menus,
/// toolbar, options bar, status) and ImageCanvasView (mouse and key
/// routing). Raw values are the toolbar group's segment indices.
enum EditorTool: Int {
    case select = 0
    case ellipseSelect
    case lasso
    case wand
    case move
    case brush
    case eraser
    case fill
    case gradient
    case text
    case eyedropper
    case crop

    /// The status bar's (and tool menu's) name for the tool.
    var displayName: String {
        switch self {
        case .select: return "Select"
        case .ellipseSelect: return "Ellipse Select"
        case .lasso: return "Lasso"
        case .wand: return "Magic Wand"
        case .move: return "Move"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .fill: return "Fill"
        case .gradient: return "Gradient"
        case .text: return "Text"
        case .eyedropper: return "Eyedropper"
        case .crop: return "Crop"
        }
    }

    /// The canvas cursor while the tool is at rest. The move tool's open
    /// hand closes mid-drag; the canvas swaps that state in itself.
    var cursor: NSCursor {
        switch self {
        case .select, .ellipseSelect, .lasso, .wand, .fill, .gradient, .brush, .eraser,
            .eyedropper, .crop:
            return .crosshair
        case .move:
            return .openHand
        case .text:
            return .iBeam
        }
    }

    /// The tool a bare Photoshop-style key selects (an unmodified,
    /// lowercased character from keyDown); nil when the character selects
    /// no tool — non-tool bare keys (brush-size brackets, Quick Mask's Q)
    /// stay in the canvas's keyDown.
    init?(keyCharacter: String) {
        switch keyCharacter {
        case "m": self = .select
        case "v": self = .move
        case "b": self = .brush
        case "e": self = .eraser
        case "t": self = .text
        case "o": self = .ellipseSelect
        case "l": self = .lasso
        case "w": self = .wand
        case "k": self = .fill
        case "g": self = .gradient
        case "i": self = .eyedropper
        case "c": self = .crop
        default: return nil
        }
    }
}
