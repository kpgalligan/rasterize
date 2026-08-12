import AppKit

/// The parameters a TEXT LAYER's pixels were rendered from: the description
/// is the source of truth, the raster only its cache. It is serialized as
/// JSON into the core's opaque per-layer metadata slot — the core stores,
/// copies and persists those bytes but never parses them, so the schema and
/// its versioning belong entirely to this side of the FFI.
///
/// The fields mirror exactly what the text tool's options bar offers: a font
/// FAMILY (the popup lists families, and `currentFont()` builds the face from
/// one), a point size, a color, and a line alignment.
///
/// JSON shape: `{"type":"text","version":1,"string":…,"font":…,"size":…,
/// "color":"#RRGGBBAA","alignment":"left"|"center"|"right"}`. `alignment` is
/// additive and optional — a payload without it (every pre-alignment file)
/// decodes as "left", so the version does not bump; encoding always writes
/// it.
struct TextLayerPayload: Codable, Equatable {
    /// The only `type` this app understands; anything else (or nothing) means
    /// the layer's metadata was written by something that is not a text
    /// layer, and the layer is a plain raster layer.
    static let typeName = "text"
    /// The only `version` this app understands. A future schema change bumps
    /// it, and older builds then read those layers as plain rasters — the
    /// graceful degradation the format is designed for.
    static let currentVersion = 1
    /// The values `alignment` may take, in options-bar segment order.
    static let alignments = ["left", "center", "right"]

    var type: String
    var version: Int
    var string: String
    /// Font FAMILY name, exactly as the options-bar popup lists it.
    var font: String
    var size: Double
    /// sRGB straight alpha, "#RRGGBBAA".
    var color: String
    /// "left" | "center" | "right" — how lines align within the text block.
    var alignment: String

    enum CodingKeys: String, CodingKey {
        case type, version, string, font, size, color, alignment
    }

    init(
        string: String, family: String, size: Double, color: NSColor,
        alignment: String = "left"
    ) {
        self.type = Self.typeName
        self.version = Self.currentVersion
        self.string = string
        self.font = family
        self.size = size
        self.color = TextLayer.hex(color)
        self.alignment = alignment
    }

    /// Snapshot of a live editing session: the font carries both the family
    /// and the size the session was laid out with.
    init(string: String, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        self.init(
            string: string, family: font.familyName ?? font.fontName,
            size: Double(font.pointSize), color: color,
            alignment: TextLayer.alignmentName(for: alignment))
    }

    /// Custom decoding only so a MISSING `alignment` (every payload written
    /// before the field existed) reads as "left"; everything else is the
    /// synthesized behavior. Encoding stays synthesized and always writes it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        version = try container.decode(Int.self, forKey: .version)
        string = try container.decode(String.self, forKey: .string)
        font = try container.decode(String.self, forKey: .font)
        size = try container.decode(Double.self, forKey: .size)
        color = try container.decode(String.self, forKey: .color)
        alignment = try container.decodeIfPresent(String.self, forKey: .alignment) ?? "left"
    }

    /// The face the raster is rendered with, built the same way the options
    /// bar builds it (`NSFontManager.font(withFamily:traits:weight:size:)`),
    /// so a committed layer matches its on-canvas preview. Falls back to the
    /// system face when the family is not installed on this machine.
    var nsFont: NSFont {
        let points = CGFloat(min(max(size, 1), 1000))
        return NSFontManager.shared.font(withFamily: font, traits: [], weight: 5, size: points)
            ?? .systemFont(ofSize: points)
    }

    var nsColor: NSColor { TextLayer.color(fromHex: color) ?? .black }

    var nsAlignment: NSTextAlignment {
        switch alignment {
        case "center": return .center
        case "right": return .right
        default: return .left
        }
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
    /// color or an unknown alignment all mean "this is a plain raster
    /// layer", never an error and never a crash.
    static func decode(_ json: String) -> TextLayerPayload? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TextLayerPayload.self, from: data),
              payload.type == typeName,
              payload.version == currentVersion,
              payload.size.isFinite, payload.size > 0,
              TextLayer.color(fromHex: payload.color) != nil,
              alignments.contains(payload.alignment)
        else { return nil }
        return payload
    }
}

/// A rendered text layer: a TIGHT straight-alpha RGBA8 raster (row 0 = top,
/// exactly `width * height * 4` bytes) plus the canvas-space offset the layer
/// must take for the glyphs to land where they were laid out.
struct TextLayerRaster {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let offsetX: Int
    let offsetY: Int
}

/// Rendering and naming for text layers — the one entry point both the text
/// tool and the agent use, so a layer committed either way looks the same.
enum TextLayer {
    /// Longest layer name derived from a string before it is elided.
    static let maxNameLength = 20

    // MARK: - Rendering

    /// Lays `payload` out at `origin` (the canvas-space top-left of the text
    /// block, i.e. the on-canvas editor's frame origin) wrapping at
    /// `wrapWidth`, and rasterizes it tightly.
    ///
    /// The layout options match the on-canvas session's exactly
    /// (`.usesLineFragmentOrigin, .usesFontLeading` — the second one keeps
    /// per-line leading identical to NSLayoutManager's), so a commit lands
    /// where its preview was. `padding(forSize:)` of slack surrounds the laid
    /// out block so antialiased edges, descenders and glyph overhang are
    /// never clipped.
    ///
    /// Alignment moves lines within the BLOCK — the tight extent of the
    /// left-aligned layout (the wrap width when the text wraps to fill it,
    /// the widest line's natural width otherwise) — never within the wrap
    /// box. That keeps the block anchored at `origin`, so the committed
    /// offset does not move when only the alignment changes, and single-line
    /// text renders identically for all three values.
    ///
    /// nil for an empty string, a degenerate layout, or a raster beyond the
    /// core's pixel cap.
    static func render(
        _ payload: TextLayerPayload, origin: CGPoint, wrapWidth: CGFloat
    ) -> TextLayerRaster? {
        guard !payload.string.isEmpty, origin.x.isFinite, origin.y.isFinite else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: payload.nsFont, .foregroundColor: payload.nsColor,
            .paragraphStyle: paragraphStyle(.left),
        ]
        // Alignment never changes line BREAKS, so the left-aligned string is
        // the geometry: block extent, sub-pixel remainders, raster size and
        // offset all come from it, for every alignment.
        let measured = NSAttributedString(string: payload.string, attributes: attributes)
        let wrap = max(wrapWidth, 1)
        let layout = measured.boundingRect(
            with: NSSize(width: wrap, height: 10_000_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        guard layout.width.isFinite, layout.height.isFinite,
              layout.width > 0, layout.height > 0,
              layout.minX.isFinite, layout.minY.isFinite
        else { return nil }

        let pad = CGFloat(padding(forSize: payload.size))
        // Canvas-space top-left of the laid-out ink box. A layer offset is
        // whole pixels, so it takes the floor and the sub-pixel remainder
        // stays INSIDE the raster — the glyphs keep their exact position.
        let inkX = origin.x + layout.minX
        let inkY = origin.y + layout.minY
        guard abs(inkX) < 1e7, abs(inkY) < 1e7 else { return nil }
        let fracX = inkX - floor(inkX)
        let fracY = inkY - floor(inkY)
        let width = Int(ceil(layout.width + fracX + pad * 2))
        let height = Int(ceil(layout.height + fracY + pad * 2))
        guard width > 0, height > 0, width * height <= RasterImage.maxResizePixels else {
            return nil
        }

        // What actually draws: the same string with the payload's alignment.
        // Left draws in the wrap box (identical to the measure); center and
        // right draw in a box exactly the block wide, so lines shift within
        // the block while the widest line — and the block itself — stay put.
        let alignment = payload.nsAlignment
        let drawnString: NSAttributedString
        let drawWidth: CGFloat
        if alignment == .left {
            drawnString = measured
            drawWidth = wrap
        } else {
            attributes[.paragraphStyle] = paragraphStyle(alignment)
            drawnString = NSAttributedString(string: payload.string, attributes: attributes)
            drawWidth = layout.width
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBufferPointer { buffer -> Bool in
            // CoreGraphics renders only into PREMULTIPLIED buffers; the
            // straight-alpha conversion happens below.
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // Flip so raster row 0 is the top row, as everywhere else.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            // Drawing at (pad + frac − layout.min) puts the ink box's
            // top-left exactly `pad` (plus the sub-pixel remainder) inside
            // the raster; drawWidth reproduces the measured line breaks.
            drawnString.draw(
                with: NSRect(
                    x: pad + fracX - layout.minX, y: pad + fracY - layout.minY,
                    width: drawWidth, height: 10_000_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard drawn else { return nil }
        Bitmap.unpremultiply(&pixels)
        return TextLayerRaster(
            pixels: pixels, width: width, height: height,
            offsetX: Int(floor(inkX)) - Int(pad), offsetY: Int(floor(inkY)) - Int(pad))
    }

    /// A paragraph style that differs from the default only in alignment —
    /// what both `render` and the on-canvas editor style their text with.
    static func paragraphStyle(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        return style
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
        let slack = Int((min(max(size, 0), 1000) * 0.2).rounded(.up))
        return min(max(slack, 4), 64)
    }

    /// Where the on-canvas editor goes when a layer is re-opened for editing:
    /// the layer's offset plus the padding `render` added, so the live glyphs
    /// sit exactly on the raster they will replace (`layout.minX/minY` are
    /// zero for the line-fragment layout used here).
    static func editorOrigin(offsetX: Int, offsetY: Int, payload: TextLayerPayload) -> CGPoint {
        let pad = CGFloat(padding(forSize: payload.size))
        return CGPoint(x: CGFloat(offsetX) + pad, y: CGFloat(offsetY) + pad)
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
    /// must have the answer before they touch the document.
    static func confirmRasterize(layerName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Rasterize text layer?"
        alert.informativeText =
            "This edit paints over “\(layerName)”, so the layer will no longer be editable "
            + "as text: the string, font, size, color and alignment it was rendered from "
            + "are dropped. The pixels themselves are kept."
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
