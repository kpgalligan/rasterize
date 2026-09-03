import AppKit

/// How a text block wraps. `unspecified` is a LEGACY layer (no `box_width`
/// key — every version-1 file written before widths were stored); it is
/// resolved to the pre-change default width at edit time
/// (`TextLayer.legacyBoxWidth`) and can never coexist with a non-identity
/// transform, because every path that rewrites a legacy layer's meta
/// materializes the box first (`LayerDescription.resolved`). `point` text
/// never wraps; `width` is paragraph text wrapping at that SOURCE-space
/// width (≥ 1).
enum TextBox: Equatable {
    case unspecified
    case point
    case width(Double)
}

/// The typography a text layer renders with — everything but the string
/// and the color. ONE attribute builder (`attributes(color:)`) and ONE face
/// builder (`nsFont`) feed both the renderer and the on-canvas NSTextView,
/// so what the session previews is what the commit renders.
struct TextStyle: Equatable {
    /// Font FAMILY name, exactly as the options-bar popup lists it.
    var family: String
    var size: Double
    /// NSFontManager weight (0…15; 3 light, 5 regular, 6 medium, 8 semibold,
    /// 9 bold) — the options bar's Weight popup scale.
    var weight = 5
    var italic = false
    /// Extra spacing between glyphs in points (`.kern`); 0 = the font's own.
    var tracking: Double = 0
    /// Line height in points: 0 = the font's natural height; > 0 pins every
    /// line to exactly this height (min = max line height) — the meaning
    /// the options bar's "Leading … pt, 0…1000" field already implies.
    var leading: Double = 0
    /// Points; positive raises the text (`.baselineOffset`).
    var baselineShift: Double = 0
    var underline = false
    var strikethrough = false
    var alignment: NSTextAlignment = .left

    init(
        family: String, size: Double, weight: Int = 5, italic: Bool = false,
        tracking: Double = 0, leading: Double = 0, baselineShift: Double = 0,
        underline: Bool = false, strikethrough: Bool = false,
        alignment: NSTextAlignment = .left
    ) {
        self.family = family
        self.size = size
        self.weight = weight
        self.italic = italic
        self.tracking = tracking
        self.leading = leading
        self.baselineShift = baselineShift
        self.underline = underline
        self.strikethrough = strikethrough
        self.alignment = alignment
    }

    /// The face, built the way the options bar builds it
    /// (`NSFontManager.font(withFamily:traits:weight:size:)`): the italic
    /// trait when asked, retried without it for a family that has no italic
    /// face, and the system face when the family is not installed here.
    /// Size clamped to 1…1000 — the payload's own validation range.
    var nsFont: NSFont {
        let points = CGFloat(min(max(size, 1), 1000))
        let manager = NSFontManager.shared
        let clampedWeight = min(max(weight, 0), 15)
        if italic, let face = manager.font(
            withFamily: family, traits: [.italicFontMask], weight: clampedWeight, size: points) {
            return face
        }
        return manager.font(withFamily: family, traits: [], weight: clampedWeight, size: points)
            ?? .systemFont(ofSize: points)
    }

    /// Whether the family is installed on this machine — the check a
    /// silent re-render must pass (see `LayerDescription.isRenderable`).
    var isInstalled: Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }


    /// The attribute set both the renderer and the on-canvas editor use.
    func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: nsFont,
            .foregroundColor: color,
            .paragraphStyle: Self.paragraphStyle(alignment: alignment, leading: leading),
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        if baselineShift != 0 { attributes[.baselineOffset] = baselineShift }
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    /// A paragraph style differing from the default only in alignment and,
    /// when `leading` is positive, a fixed line height.
    static func paragraphStyle(alignment: NSTextAlignment, leading: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        if leading > 0, leading.isFinite {
            style.minimumLineHeight = CGFloat(leading)
            style.maximumLineHeight = CGFloat(leading)
        }
        return style
    }
}

/// The parameters a TEXT LAYER's pixels were rendered from: the description
/// is the source of truth, the raster only its cache. It is serialized as
/// JSON into the core's opaque per-layer metadata slot — the core stores,
/// copies and persists those bytes but never parses them, so the schema and
/// its versioning belong entirely to this side of the FFI.
///
/// JSON shape, version 1 (the default-typography, untransformed case):
/// `{"type":"text","version":1,"string":…,"font":…,"size":…,
/// "color":"#RRGGBBAA","alignment":"left"|"center"|"right","box_width":…}`.
/// `alignment` is additive and optional (missing = "left"); `box_width` is
/// additive too — a number ≥ 1 for paragraph text, `0` for point text, and
/// ABSENT only in legacy files (older builds ignore it and re-wrap at their
/// own default, which is what they do today).
///
/// Version 2 adds, and is written only when one of them is off its default:
/// `weight` (5), `italic` (false), `tracking` (0), `leading` (0),
/// `baseline_shift` (0), `underline` (false), `strikethrough` (false),
/// `transform` (`[a, b, c, d]`, row-major: x′ = a·x + b·y, y′ = c·x + d·y —
/// see `LinearMap`; default the identity) and `origin_frac` (`[fx, fy]`, the
/// fraction of the anchor, default `[0, 0]`). A version-1 payload decodes
/// as version 2 with the defaults; version 1 is written whenever every
/// version-2 field is at its default, so files whose layers are
/// untransformed keep opening as editable text in older builds.
struct TextLayerPayload: Codable, Equatable {
    /// The only `type` this app understands; anything else (or nothing) means
    /// the layer's metadata was written by something that is not a text
    /// layer, and the layer is a plain raster layer.
    static let typeName = "text"
    /// The newest schema this app writes; older builds read layers at it as
    /// plain rasters — the graceful degradation the format is designed for.
    static let currentVersion = 2
    /// The schema written when every version-2 field is at its default.
    static let legacyVersion = 1
    /// The values `alignment` may take, in options-bar segment order.
    static let alignments = ["left", "center", "right"]

    var string: String
    /// Font FAMILY name, exactly as the options-bar popup lists it.
    var font: String
    var size: Double
    /// sRGB straight alpha, "#RRGGBBAA".
    var color: String
    /// "left" | "center" | "right" — how lines align within the text block.
    var alignment: String
    var weight = 5
    var italic = false
    var tracking: Double = 0
    var leading: Double = 0
    var baselineShift: Double = 0
    var underline = false
    var strikethrough = false
    var box: TextBox = .unspecified
    /// The 2×2 linear part of the layer's placement (DescribedLayer.swift).
    var transform: LinearMap = .identity
    /// The fraction of the anchor, each component in [0, 1); written only
    /// by `addingDescribedLayer` / `rerenderingDescribedLayer` and the
    /// meta-only geometry patches, never by a caller building a payload.
    var originFraction: CGPoint = .zero

    enum CodingKeys: String, CodingKey {
        case type, version, string, font, size, color, alignment
        case weight, italic, tracking, leading, underline, strikethrough, transform
        case baselineShift = "baseline_shift"
        case boxWidth = "box_width"
        case originFraction = "origin_frac"
    }

    init(
        string: String, style: TextStyle, color: NSColor, box: TextBox,
        transform: LinearMap = .identity
    ) {
        self.string = string
        self.font = style.family
        self.size = style.size
        self.color = TextLayer.hex(color)
        self.alignment = TextLayer.alignmentName(for: style.alignment)
        self.weight = style.weight
        self.italic = style.italic
        self.tracking = style.tracking
        self.leading = style.leading
        self.baselineShift = style.baselineShift
        self.underline = style.underline
        self.strikethrough = style.strikethrough
        self.box = box
        self.transform = transform
    }

    /// Decoding validates `type` and `version` (neither is stored: encoding
    /// writes them back); a missing version-2 key reads as its default, a
    /// malformed one throws — `decode` turns every throw into "not a text
    /// layer".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let version = try container.decode(Int.self, forKey: .version)
        guard type == Self.typeName, version == Self.legacyVersion || version == Self.currentVersion
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "not a text payload")
        }
        string = try container.decode(String.self, forKey: .string)
        font = try container.decode(String.self, forKey: .font)
        size = try container.decode(Double.self, forKey: .size)
        color = try container.decode(String.self, forKey: .color)
        alignment = try container.decodeIfPresent(String.self, forKey: .alignment) ?? "left"
        weight = try container.decodeIfPresent(Int.self, forKey: .weight) ?? 5
        italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        tracking = try container.decodeIfPresent(Double.self, forKey: .tracking) ?? 0
        leading = try container.decodeIfPresent(Double.self, forKey: .leading) ?? 0
        baselineShift = try container.decodeIfPresent(Double.self, forKey: .baselineShift) ?? 0
        underline = try container.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        strikethrough = try container.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        if let width = try container.decodeIfPresent(Double.self, forKey: .boxWidth) {
            if width == 0 {
                box = .point
            } else if width.isFinite, width >= 1 {
                box = .width(width)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .boxWidth, in: container, debugDescription: "box_width out of range")
            }
        } else {
            box = .unspecified
        }
        if let elements = try container.decodeIfPresent([Double].self, forKey: .transform) {
            guard let map = LinearMap(array: elements) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .transform, in: container, debugDescription: "malformed transform")
            }
            transform = map
        }
        if let pair = try container.decodeIfPresent([Double].self, forKey: .originFraction) {
            guard let frac = TextLayer.originFraction(from: pair) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .originFraction, in: container,
                    debugDescription: "malformed origin_frac")
            }
            originFraction = frac
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.typeName, forKey: .type)
        let legacy = isLegacyEncodable
        try container.encode(legacy ? Self.legacyVersion : Self.currentVersion, forKey: .version)
        try container.encode(string, forKey: .string)
        try container.encode(font, forKey: .font)
        try container.encode(size, forKey: .size)
        try container.encode(color, forKey: .color)
        try container.encode(alignment, forKey: .alignment)
        switch box {
        case .unspecified: break
        case .point: try container.encode(0.0, forKey: .boxWidth)
        case let .width(width): try container.encode(width, forKey: .boxWidth)
        }
        guard !legacy else { return }
        try container.encode(weight, forKey: .weight)
        try container.encode(italic, forKey: .italic)
        try container.encode(tracking, forKey: .tracking)
        try container.encode(leading, forKey: .leading)
        try container.encode(baselineShift, forKey: .baselineShift)
        try container.encode(underline, forKey: .underline)
        try container.encode(strikethrough, forKey: .strikethrough)
        try container.encode(transform.array, forKey: .transform)
        try container.encode(TextLayer.originFractionArray(originFraction), forKey: .originFraction)
    }

    /// True when every version-2 field is at its default, so the payload
    /// can be written as version 1 (the box is version-1 compatible and
    /// does not count).
    var isLegacyEncodable: Bool {
        transform.isIdentity && originFraction == .zero && weight == 5 && !italic
            && tracking == 0 && leading == 0 && baselineShift == 0 && !underline
            && !strikethrough
    }

    /// The typography the payload renders with.
    var style: TextStyle {
        TextStyle(
            family: font, size: size, weight: weight, italic: italic, tracking: tracking,
            leading: leading, baselineShift: baselineShift, underline: underline,
            strikethrough: strikethrough, alignment: nsAlignment)
    }

    var nsColor: NSColor { TextLayer.color(fromHex: color) ?? .black }

    var nsAlignment: NSTextAlignment {
        switch alignment {
        case "center": return .center
        case "right": return .right
        default: return .left
        }
    }

    func withBox(_ box: TextBox) -> TextLayerPayload {
        var updated = self
        updated.box = box
        return updated
    }

    func withOriginFraction(_ frac: CGPoint) -> TextLayerPayload {
        var updated = self
        updated.originFraction = frac
        return updated
    }

    /// A legacy unspecified box materialized as paragraph text `width` wide
    /// (at least 1); any other box is kept.
    func resolvingLegacyBox(width: Double) -> TextLayerPayload {
        guard box == .unspecified else { return self }
        return withBox(.width(max(width, 1)))
    }

    /// The JSON to store as the layer's metadata; nil only if the payload
    /// somehow cannot be encoded. Keys are sorted so re-encoding an unchanged
    /// description produces identical bytes.
    func json() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Strict, non-throwing decode: malformed JSON, a missing or unknown
    /// `type`, an unsupported `version`, a non-positive size, an unparseable
    /// color, an unknown alignment, a weight off the 0…15 scale, a
    /// non-finite typography value, a negative leading, a singular or
    /// non-finite transform, or an out-of-range fraction all mean "this is
    /// a plain raster layer", never an error and never a crash.
    static func decode(_ json: String) -> TextLayerPayload? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TextLayerPayload.self, from: data),
              payload.size.isFinite, payload.size > 0,
              TextLayer.color(fromHex: payload.color) != nil,
              alignments.contains(payload.alignment),
              (0...15).contains(payload.weight),
              payload.tracking.isFinite, payload.leading.isFinite, payload.leading >= 0,
              payload.baselineShift.isFinite,
              payload.transform.isInvertible,
              TextLayer.isValidFraction(payload.originFraction)
        else { return nil }
        return payload
    }
}

/// Rendering and naming for text layers — the one entry point both the text
/// tool and the agent use, so a layer committed either way looks the same.
enum TextLayer {
    /// Longest layer name derived from a string before it is elided.
    static let maxNameLength = 20

    /// The wrap width the point-text layout measures in: wide enough that
    /// no line a document could hold ever wraps.
    static let unboundedWidth: CGFloat = 10_000_000

    /// The widest box paragraph text may wrap at, in px — the ONE cap the
    /// on-canvas editor (`ImageCanvasView.beginTextSession`) and the agent's
    /// `wrap_width` (`AgentServer.textBoxArg`) both clamp to, so a width the
    /// agent stored comes back from the editor unchanged and closing a
    /// reopened layer untouched registers no phantom edit. Wide enough for
    /// any line a document can hold; far below `unboundedWidth`, the
    /// point-text measure.
    static let maxBoxWidth: Double = 100_000

    // MARK: - The legacy box

    /// The wrap width a text layer written before widths were stored
    /// re-wraps at — the on-canvas editor's own pre-change rule, verbatim:
    /// `min(600, max(bounds.width - point.x, 40))`. The ONE home of that
    /// formula: the canvas editor's default width, the geometry sync and the
    /// Free Transform compose all read it here.
    static func legacyBoxWidth(canvasWidth: CGFloat, anchorX: CGFloat) -> CGFloat {
        min(600, max(canvasWidth - anchorX, 40))
    }

    /// The wrap width a legacy layer (no stored `box_width`) is materialized
    /// at by the non-interactive paths (Free Transform, transform_layer, the
    /// document geometry sync): recovered from the RASTER rather than
    /// guessed. Under the identity — the only map an unspecified box ever
    /// sits under — the raster is `ceil(widest line + fraction + 2·pad)`
    /// wide, so `rasterWidth − 2·pad` is the widest line's width rounded up
    /// by less than two pixels. A container that wide reproduces the
    /// existing line breaks under greedy word wrapping whatever the original
    /// wrap width was: every existing line fits (none is wider than the
    /// widest), and no line can take its successor's first word, because
    /// that word did not fit beside it in the original width, which was at
    /// least the widest line's, and the recovered width overshoots that by
    /// under two pixels — less than any glyph plus the space before it. The
    /// pre-change defaults are not recoverable from a raster and re-wrapped
    /// a one-line title into two when they guessed narrow (the UI's 600 px
    /// cap against an agent-made 900 px line); this never re-wraps. At
    /// least 1. The on-canvas editor's reopen keeps `legacyBoxWidth`: there
    /// the width is the box the user sees and re-edits.
    static func boxWidth(fittingRasterWidth rasterWidth: Int, size: Double) -> Double {
        Double(max(rasterWidth - 2 * padding(forSize: size), 1))
    }

    // MARK: - Layout

    /// The wrap width a box lays out in; nil for an unresolved legacy box.
    static func wrapWidth(_ box: TextBox) -> CGFloat? {
        switch box {
        case .unspecified: return nil
        case .point: return unboundedWidth
        case let .width(width): return CGFloat(max(width, 1))
        }
    }

    /// The TextKit stack the on-canvas session lays `string` out with — one
    /// storage, one layout manager, one container `wrap` wide and taller
    /// than any document (`unboundedWidth`) with zero line-fragment padding
    /// (`ImageCanvasView.beginTextSession`) — with layout complete.
    /// Measuring AND drawing through this same stack is what makes a commit
    /// land exactly where the session showed it, glyph for glyph: the
    /// session's NSTextView draws through `NSLayoutManager.drawGlyphs`, and
    /// NSStringDrawing's `draw(with:)` — pixel-identical to it otherwise —
    /// lifts every later line by a POSITIVE baseline shift on top of the
    /// typesetter's positions (cumulatively, and at any leading), so a
    /// shifted two-line block committed through it would sit up to a line
    /// above the preview. The storage is returned only to keep it alive:
    /// the manager holds it weakly.
    /// The stack `typeset` builds, kept whole so the renderer can draw
    /// through the very stack that measured the block.
    private typealias TypesetStack = (
        manager: NSLayoutManager, container: NSTextContainer, storage: NSTextStorage
    )

    private static func typeset(_ string: NSAttributedString, wrap: CGFloat) -> TypesetStack {
        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: wrap, height: unboundedWidth))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return (manager, container, storage)
    }

    /// The left-aligned layout of `payload` in SOURCE coordinates (a frame
    /// whose origin is the layout origin): the measured string, with the
    /// payload's full attribute set, and its INK-SAFE rect — the block's
    /// used rect (what NSStringDrawing's `boundingRect` reports too),
    /// extended over any line whose glyphs the typesetter places above or
    /// below it. Under a fixed line height tighter than the font's natural
    /// height TextKit pins each baseline at round(height − descent), and a
    /// positive baseline shift raises it further, so the first line's
    /// ascent — 45 px of a 48 pt Helvetica Neue at a leading of 10 — sits
    /// above the block and is drawn there regardless; the raster has to
    /// cover it. Each line's ink is bounded by the font's ascender above its
    /// baseline (`NSLayoutManager.location`, which matches the drawn
    /// baseline to the pixel) and its descender below; accents and swashes
    /// beyond those are what `padding(forSize:)` is for. At the natural
    /// height every line stays inside the used rect, so a version-1 layer's
    /// rect is exactly its pre-typography one.
    ///
    /// Alignment never changes line BREAKS, so the left-aligned layout is
    /// the geometry for every alignment. nil for an unresolved legacy box —
    /// resolve the box first (`LayerDescription.resolved`): a legacy
    /// paragraph must never lay out as one line — an empty string, or a
    /// non-finite or empty rect.
    static func layout(_ payload: TextLayerPayload) -> (measured: NSAttributedString, rect: CGRect)? {
        measure(payload).map { ($0.measured, $0.rect) }
    }

    /// `layout` plus the TextKit stack that measured it: ONE typesetting
    /// pass serves the measure, the padded source rect and — for
    /// left-aligned text — the draw itself (`render`), where a commit used
    /// to lay the same string out once per question, linear in its length.
    private static func measure(_ payload: TextLayerPayload)
        -> (measured: NSAttributedString, rect: CGRect, stack: TypesetStack)?
    {
        guard !payload.string.isEmpty, let wrap = wrapWidth(payload.box) else { return nil }
        var style = payload.style
        style.alignment = .left
        let measured = NSAttributedString(
            string: payload.string, attributes: style.attributes(color: payload.nsColor))
        let typeset = typeset(measured, wrap: wrap)
        var rect = typeset.manager.usedRect(for: typeset.container)
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0,
              rect.minX.isFinite, rect.minY.isFinite
        else { return nil }
        // Only a FIXED line height can put ink outside the used rect; at the
        // natural height TextKit sizes every fragment to hold its glyphs (a
        // baseline shift of either sign included). The union is skipped there
        // rather than trusted to be a no-op because TextKit rounds baselines
        // to whole pixels, so ascender and descender poke a fraction of a
        // pixel past the used rect for some faces (Georgia, Menlo, Zapfino),
        // and the raster rect's outward rounding would turn that into a row a
        // legacy raster does not have — moving its recovered anchor by a
        // pixel and making the geometry sync re-render every such layer.
        guard style.leading > 0 else { return (measured, rect, typeset) }
        let font = style.nsFont
        let manager = typeset.manager
        var glyph = 0
        let glyphCount = manager.numberOfGlyphs
        while glyph < glyphCount {
            var lineGlyphs = NSRange(location: 0, length: 0)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            let baseline = fragment.minY + manager.location(forGlyphAt: glyph).y
            let ink = CGRect(
                x: rect.minX, y: baseline - font.ascender,
                width: rect.width, height: font.ascender - font.descender)
            if ink.minY.isFinite, ink.height.isFinite, ink.height > 0 {
                rect = rect.union(ink)
            }
            guard lineGlyphs.length > 0 else { break }
            glyph = NSMaxRange(lineGlyphs)
        }
        return (measured, rect, typeset)
    }

    /// The padded source rect (DescribedLayer.swift): the ink-safe layout
    /// rect inset by −`padding(forSize:)` on every side. For a version-1
    /// layer the layout rect is the plain used rect, so legacy rasters and
    /// the (−pad, −pad) origin rule of `LayerDescription.rasterOrigin` are
    /// untouched.
    static func sourceRect(_ payload: TextLayerPayload) -> CGRect? {
        layout(payload).map { sourceRect(layoutRect: $0.rect, size: payload.size) }
    }

    /// `sourceRect` for a layout rect already measured, so a caller holding
    /// the layout (the renderer) does not lay the string out again.
    static func sourceRect(layoutRect: CGRect, size: Double) -> CGRect {
        let pad = CGFloat(padding(forSize: size))
        return layoutRect.insetBy(dx: -pad, dy: -pad)
    }

    // MARK: - Rendering

    /// Renders `payload` with its layout origin at `anchor` (canvas space)
    /// through its transform, tightly: the raster is the outward-rounded
    /// box of the padded layout under the map (`LinearMap.rasterRect`), the
    /// glyphs drawn by the session's own TextKit stack (`typeset`) under
    /// the CTM with antialiasing (crisp vector edges at any angle), and the
    /// offset is `floor(anchor) + rect.origin`. Under the identity this
    /// reproduces the pre-transform raster exactly, sub-pixel remainder
    /// included.
    ///
    /// Alignment moves lines within the BLOCK — the tight extent of the
    /// left-aligned layout (the wrap width when the text wraps to fill it,
    /// the widest line's natural width otherwise) — never within the wrap
    /// box. That keeps the block anchored, so the offset does not move when
    /// only the alignment changes, and single-line text renders identically
    /// for all three values.
    ///
    /// MAIN THREAD ONLY (AppKit drawing). nil for an unresolved box, an
    /// empty string, a degenerate layout, a non-finite anchor, or a raster
    /// beyond the core's pixel cap.
    static func render(_ payload: TextLayerPayload, anchor: CGPoint) -> DescribedRaster? {
        guard anchor.x.isFinite, anchor.y.isFinite, abs(anchor.x) < 1e7, abs(anchor.y) < 1e7,
              let layout = measure(payload)
        else { return nil }
        let source = sourceRect(layoutRect: layout.rect, size: payload.size)
        let frac = DescribedLayer.anchorFraction(anchor)
        guard let rect = payload.transform.rasterRect(of: source, fraction: frac) else {
            return nil
        }

        // What actually draws: the same string with the payload's alignment.
        // Left draws through the very stack that measured the block — the
        // same string in the same wrap width, so the measure IS the draw's
        // typesetting; center and right lay the aligned string out in a box
        // exactly the block wide, so lines shift within the block while the
        // widest line — and the block itself — stay put.
        let stack: TypesetStack
        if payload.nsAlignment == .left {
            stack = layout.stack
        } else {
            stack = typeset(
                NSAttributedString(
                    string: payload.string,
                    attributes: payload.style.attributes(color: payload.nsColor)),
                wrap: layout.rect.width)
        }

        let pixels = Bitmap.renderStraightRGBA(
            width: rect.width, height: rect.height, appKit: true
        ) { context in
            // Source space → raster: the anchor's fraction, less the rect's
            // origin (relative to the anchor's whole part), after the map.
            context.translateBy(
                x: frac.x - CGFloat(rect.originX), y: frac.y - CGFloat(rect.originY))
            context.concatenate(payload.transform.cgAffine)
            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(false)
            // The stack that measured the block draws it (see `typeset`),
            // at the layout origin; the background pass carries nothing
            // today (no background-color attribute) and is kept so the two
            // passes stay the NSTextView's pair.
            let glyphs = stack.manager.glyphRange(for: stack.container)
            stack.manager.drawBackground(forGlyphRange: glyphs, at: .zero)
            stack.manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            return true
        }
        guard let pixels = pixels else { return nil }
        return DescribedRaster(
            pixels: pixels, width: rect.width, height: rect.height,
            offsetX: Int(anchor.x.rounded(.down)) + rect.originX,
            offsetY: Int(anchor.y.rounded(.down)) + rect.originY)
    }

    /// The payload string for an alignment ("left" | "center" | "right");
    /// anything the payload cannot express maps to "left".
    static func alignmentName(for alignment: NSTextAlignment) -> String {
        switch alignment {
        case .center: return "center"
        case .right: return "right"
        default: return "left"
        }
    }

    /// Slack kept around the laid-out block, in pixels: enough for
    /// antialiased edges and for glyphs that overhang their layout box
    /// (italics, swashes), and growing with the type size.
    static func padding(forSize size: Double) -> Int {
        // NaN passes through min/max (neither comparison holds) and would
        // trap in the Int conversion. A decoded payload never carries one
        // (`decode` checks), but a style built from an argument can.
        guard size.isFinite else { return 4 }
        let slack = Int((min(max(size, 0), 1000) * 0.2).rounded(.up))
        return min(max(slack, 4), 64)
    }

    // MARK: - The origin fraction on the wire

    /// `[fx, fy]` as decoded: exactly two finite numbers in [0, 1).
    static func originFraction(from pair: [Double]) -> CGPoint? {
        guard pair.count == 2 else { return nil }
        let point = CGPoint(x: pair[0], y: pair[1])
        return isValidFraction(point) ? point : nil
    }

    static func isValidFraction(_ frac: CGPoint) -> Bool {
        frac.x.isFinite && frac.y.isFinite && frac.x >= 0 && frac.x < 1 && frac.y >= 0
            && frac.y < 1
    }

    /// `[fx, fy]` for encoding, signed zero normalized.
    static func originFractionArray(_ frac: CGPoint) -> [Double] {
        [Double(frac.x), Double(frac.y)].map { $0 == 0 ? 0 : $0 }
    }

    // MARK: - Naming

    /// The layer name a piece of text gets: its first ~20 characters on one
    /// line, elided. Whitespace runs (including newlines) collapse to single
    /// spaces so a multi-line block still reads as one label.
    static func layerName(for string: String) -> String {
        let collapsed = string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return "Text" }
        guard collapsed.count > maxNameLength else { return collapsed }
        let head = String(collapsed.prefix(maxNameLength))
            .trimmingCharacters(in: .whitespaces)
        return head + "…"
    }

    // MARK: - Color hex

    /// "#RRGGBBAA" in sRGB with straight alpha.
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? .black
        let byte: (CGFloat) -> Int = { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X%02X",
            byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent),
            byte(c.alphaComponent))
    }

    /// Parses "#RRGGBBAA" (and the alpha-less "#RRGGBB"); nil on anything
    /// else, which is what makes a malformed payload decode as "not text".
    static func color(fromHex string: String) -> NSColor? {
        var digits = string.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8,
              let value = UInt32(digits, radix: 16)
        else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha)
    }

    // MARK: - Rasterize prompt

    /// Asks whether a destructive edit may drop a layer's text description.
    /// App-modal (not a sheet) on purpose: the edit paths that ask — a filter
    /// commit, a fill click, a finished brush stroke — are synchronous and
    /// must have the answer before they touch the document. `reason`, when
    /// given, says why THIS edit has to rasterize (a Free Transform on a
    /// layer whose family is not installed here).
    static func confirmRasterize(layerName: String, reason: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Rasterize text layer?"
        var text =
            "This edit paints over “\(layerName)”, so the layer will no longer be editable "
            + "as text: the description it was rendered from (its text, typography and "
            + "transform) is dropped. The pixels themselves are kept."
        if let reason = reason { text += "\n\n" + reason }
        alert.informativeText = text
        alert.addButton(withTitle: "Rasterize")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Reading and writing the payload on a document layer

extension RasterDocument {
    /// Layer `idx`'s text description, or nil when it has none (a plain
    /// raster layer, or metadata this app does not recognize).
    func textPayload(_ idx: Int) -> TextLayerPayload? {
        guard let meta = layerMeta(idx) else { return nil }
        return TextLayerPayload.decode(meta)
    }

    /// Attaches `payload` to layer `idx` as its metadata (pure, like every
    /// other layer op — pixels and offset are the caller's to chain).
    func withTextPayload(_ idx: Int, _ payload: TextLayerPayload) -> RasterDocument? {
        guard let json = payload.json() else { return nil }
        return withLayerMeta(idx, json)
    }
}
