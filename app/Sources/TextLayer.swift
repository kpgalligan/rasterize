import AppKit

/// The parameters a TEXT LAYER's pixels were rendered from: the description
/// is the source of truth, the raster only its cache. It is serialized as
/// JSON into the core's opaque per-layer metadata slot — the core stores,
/// copies and persists those bytes but never parses them, so the schema and
/// its versioning belong entirely to this side of the FFI.
///
/// The fields mirror exactly what the text tool's options bar offers: a font
/// FAMILY (the popup lists families, and `currentFont()` builds the face from
/// one), a point size, and a color. There is no alignment control, so there
/// is no alignment field.
///
/// JSON shape: `{"type":"text","version":1,"string":…,"font":…,"size":…,
/// "color":"#RRGGBBAA"}`.
struct TextLayerPayload: Codable, Equatable {
    /// The only `type` this app understands; anything else (or nothing) means
    /// the layer's metadata was written by something that is not a text
    /// layer, and the layer is a plain raster layer.
    static let typeName = "text"
    /// The only `version` this app understands. A future schema change bumps
    /// it, and older builds then read those layers as plain rasters — the
    /// graceful degradation the format is designed for.
    static let currentVersion = 1

    var type: String
    var version: Int
    var string: String
    /// Font FAMILY name, exactly as the options-bar popup lists it.
    var font: String
    var size: Double
    /// sRGB straight alpha, "#RRGGBBAA".
    var color: String

    init(string: String, family: String, size: Double, color: NSColor) {
        self.type = Self.typeName
        self.version = Self.currentVersion
        self.string = string
        self.font = family
        self.size = size
        self.color = TextLayer.hex(color)
    }

    /// Snapshot of a live editing session: the font carries both the family
    /// and the size the session was laid out with.
    init(string: String, font: NSFont, color: NSColor) {
        self.init(
            string: string, family: font.familyName ?? font.fontName,
            size: Double(font.pointSize), color: color)
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
    /// `type`, an unsupported `version`, a non-positive size or an
    /// unparseable color all mean "this is a plain raster layer", never an
    /// error and never a crash.
    static func decode(_ json: String) -> TextLayerPayload? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TextLayerPayload.self, from: data),
              payload.type == typeName,
              payload.version == currentVersion,
              payload.size.isFinite, payload.size > 0,
              TextLayer.color(fromHex: payload.color) != nil
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
    /// nil for an empty string, a degenerate layout, or a raster beyond the
    /// core's pixel cap.
    static func render(
        _ payload: TextLayerPayload, origin: CGPoint, wrapWidth: CGFloat
    ) -> TextLayerRaster? {
        guard !payload.string.isEmpty, origin.x.isFinite, origin.y.isFinite else { return nil }
        let attributed = NSAttributedString(
            string: payload.string,
            attributes: [.font: payload.nsFont, .foregroundColor: payload.nsColor])
        let wrap = max(wrapWidth, 1)
        let layout = attributed.boundingRect(
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
            // the raster; the width stays `wrap` so lines break identically.
            attributed.draw(
                with: NSRect(
                    x: pad + fracX - layout.minX, y: pad + fracY - layout.minY,
                    width: wrap, height: 10_000_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard drawn else { return nil }
        unpremultiply(&pixels)
        return TextLayerRaster(
            pixels: pixels, width: width, height: height,
            offsetX: Int(floor(inkX)) - Int(pad), offsetY: Int(floor(inkY)) - Int(pad))
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

    /// Straight-alpha conversion of a premultiplied RGBA8 buffer: layer
    /// pixels cross the FFI with straight alpha (only the painting overlay is
    /// premultiplied). Fully transparent pixels carry no color at all.
    private static func unpremultiply(_ pixels: inout [UInt8]) {
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            if alpha == 255 { continue }
            if alpha == 0 {
                pixels[i] = 0
                pixels[i + 1] = 0
                pixels[i + 2] = 0
                continue
            }
            for channel in 0..<3 {
                let value = (Int(pixels[i + channel]) * 255 + alpha / 2) / alpha
                pixels[i + channel] = UInt8(min(value, 255))
            }
        }
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
            + "as text: the string, font, size and color it was rendered from are dropped. "
            + "The pixels themselves are kept."
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
