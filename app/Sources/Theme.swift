import AppKit

/// Design tokens. Chrome colors come from the semantic AppKit system palette
/// so the app matches the OS in both appearances — an image editor's chrome
/// should stay neutral. The only fixed colors are the brand mark (welcome
/// motif, selection marquee) and the transparency checkerboard; fonts remain
/// the vendored Balopy faces.
enum DS {
    // MARK: - Chrome colors (system palette)

    static var chromeBackground: NSColor { .windowBackgroundColor }
    static var hoverFill: NSColor { .quaternaryLabelColor }
    static var selectionFill: NSColor { .controlAccentColor.withAlphaComponent(0.22) }
    static var border: NSColor { .separatorColor }
    static var borderStrong: NSColor { .tertiaryLabelColor }
    /// The crisp offset block behind sticker controls.
    static var stickerShadow: NSColor { .shadowColor }
    static var textStrong: NSColor { .labelColor }
    static var textMuted: NSColor { .secondaryLabelColor }
    static var textFaint: NSColor { .tertiaryLabelColor }
    static var accent: NSColor { .controlAccentColor }
    static var onAccent: NSColor { .white }
    static var canvasVoid: NSColor { .underPageBackgroundColor }

    // MARK: - Fixed colors

    /// Brand inks — used only by the welcome motif and the marquee.
    static let forest = NSColor(srgbRed: 0x1F / 255, green: 0x85 / 255, blue: 0x64 / 255, alpha: 1)
    static let butter = NSColor(srgbRed: 0xF2 / 255, green: 0xC1 / 255, blue: 0x4E / 255, alpha: 1)
    static let coral = NSColor(srgbRed: 0xF4 / 255, green: 0x65 / 255, blue: 0x3F / 255, alpha: 1)

    /// The selection marquee — the app's one accent-colored canvas element.
    static var marquee: NSColor { coral.withAlphaComponent(0.9) }

    /// Neutral checkerboard for transparency, constant across appearances so
    /// transparent pixels always read against the same reference.
    static let checkerA = NSColor(white: 0.886, alpha: 1)
    static let checkerB = NSColor(white: 0.941, alpha: 1)

    /// The document grid and the pixel lattice. Deliberately the SEMANTIC
    /// label colour rather than an ink of its own: a grid is a measuring
    /// aid, not a mark, so it should follow the appearance the way the rest
    /// of the chrome does. The alpha is applied at the draw site, because
    /// the major lines, the subdivisions and the pixel lattice each want a
    /// different weight of the same colour.
    static var gridInk: NSColor { .labelColor }

    // MARK: - Type

    /// Source Sans 3 for UI text; system face when the vendored font is
    /// missing. Variable-font named instances resolve per weight.
    static func sans(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name: String
        switch weight {
        case .semibold: name = "SourceSans3-SemiBold"
        case .bold: name = "SourceSans3-Bold"
        default: name = "SourceSans3-Regular"
        }
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// IBM Plex Mono for machine-produced numbers.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name = weight == .regular ? "IBMPlexMono-Regular" : "IBMPlexMono-Medium"
        return NSFont(name: name, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Darker Grotesque for display headlines only, never below 28px.
    static func display(_ size: CGFloat) -> NSFont {
        NSFont(name: "DarkerGrotesque-Black", size: size)
            ?? .systemFont(ofSize: size, weight: .black)
    }

    /// 10-11px uppercase micro-label attributes (0.09em tracking).
    static func microLabel(_ text: String, size: CGFloat = 10) -> NSAttributedString {
        NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: mono(size),
                .kern: size * 0.09,
                .foregroundColor: textFaint,
            ])
    }

    // MARK: - Metrics (the redesign's fixed chrome dimensions)

    static let railWidth: CGFloat = 48
    static let railSlot: CGFloat = 34
    static let railSlotRadius: CGFloat = 5
    static let optionsBarHeight: CGFloat = 36
    static let controlHeight: CGFloat = 22
    static let controlRadius: CGFloat = 3
    static let statusBarHeight: CGFloat = 26
    static let panelWidth: CGFloat = 304
    static let tabHeight: CGFloat = 32
    static let layerRow: CGFloat = 44
    static let popoverWidth: CGFloat = 268
    static let menuMinWidth: CGFloat = 206
    static let canvasInset: CGFloat = 36
    /// The ruler strips' thickness, and the side of the square corner box
    /// they meet in. 18 pt fits a `DS.mono(9)` numeral plus the three tick
    /// lengths in chrome whose other bars are 36 (options) and 26 (status).
    static let rulerThickness: CGFloat = 18

    // MARK: - Motion

    static let hoverDuration: TimeInterval = 0.14
    static let stateDuration: TimeInterval = 0.22

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func animate(_ duration: TimeInterval, _ changes: () -> Void) {
        if reduceMotion {
            changes()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
            context.allowsImplicitAnimation = true
            changes()
        }
    }
}
