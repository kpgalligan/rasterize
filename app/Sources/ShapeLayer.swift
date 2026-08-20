import AppKit

/// The parameters a SHAPE LAYER's pixels were rendered from: the description
/// is the source of truth, the raster only its cache. Like a text layer's
/// payload it is serialized as JSON into the core's opaque per-layer metadata
/// slot — the core stores, copies and persists those bytes but never parses
/// them, so the schema and its versioning belong entirely to this side of the
/// FFI.
///
/// Geometry is layer-LOCAL, deliberately: the payload stores only the shape
/// box's SIZE (`w` × `h`) and styling, never a canvas position. Where the
/// shape sits on the canvas is the layer's offset, like every other layer —
/// which is what lets the Move tool move a shape layer without invalidating
/// its description, and keeps the description true after any offset-only
/// edit.
///
/// JSON shape: `{"type":"shape","version":1,"kind":"rect"|"ellipse"|"line",
/// "w":…,"h":…,"flipped":bool?,"fill":"#RRGGBBAA"|"","stroke":"#RRGGBBAA"|"",
/// "strokeWidth":…,"radius":…}`. `flipped` is additive and optional — a
/// payload without it decodes as false, so the version does not bump;
/// encoding always writes it.
struct ShapeLayerPayload: Codable, Equatable {
    /// The only `type` this app understands; anything else (or nothing) means
    /// the layer's metadata was written by something that is not a shape
    /// layer, and the layer is a plain raster layer.
    static let typeName = "shape"
    /// The only `version` this app understands. A future schema change bumps
    /// it, and older builds then read those layers as plain rasters — the
    /// graceful degradation the format is designed for.
    static let currentVersion = 1
    /// The values `kind` may take.
    static let kinds = ["rect", "ellipse", "line"]

    var type: String
    var version: Int
    /// "rect" | "ellipse" | "line".
    var kind: String
    /// Shape box size in pixels — the SHAPE's box, not the raster's (the
    /// raster is the box plus `ShapeLayer.padding(for:)` on every side).
    var w: Double
    var h: Double
    /// Line only: false = the line runs from the box's top-left to its
    /// bottom-right; true = bottom-left to top-right. Meaningless (and always
    /// encoded false) for rect/ellipse.
    var flipped: Bool
    /// sRGB straight alpha, "#RRGGBBAA"; "" = no fill. Always "" for lines.
    var fill: String
    /// sRGB straight alpha, "#RRGGBBAA"; "" = no stroke.
    var stroke: String
    /// Stroke width in pixels, centered on the path.
    var strokeWidth: Double
    /// Rect corner radius in pixels; ignored by ellipse/line.
    var radius: Double

    enum CodingKeys: String, CodingKey {
        case type, version, kind, w, h, flipped, fill, stroke, strokeWidth, radius
    }

    /// Builds a payload with canonical bytes: `fill` is forced to "" for
    /// lines, `flipped` to false for rect/ellipse, and `radius` to 0 for
    /// anything but a rect, so re-encoding never carries fields the kind
    /// ignores.
    init(
        kind: String, w: Double, h: Double, flipped: Bool = false,
        fill: NSColor?, stroke: NSColor?, strokeWidth: Double, radius: Double = 0
    ) {
        self.type = Self.typeName
        self.version = Self.currentVersion
        self.kind = kind
        self.w = w
        self.h = h
        let isLine = kind == "line"
        self.flipped = isLine ? flipped : false
        self.fill = isLine ? "" : (fill.map { TextLayer.hex($0) } ?? "")
        self.stroke = stroke.map { TextLayer.hex($0) } ?? ""
        self.strokeWidth = strokeWidth
        self.radius = kind == "rect" ? radius : 0
    }

    /// Custom decoding only so a MISSING `flipped` (every payload written
    /// before the field existed) reads as false; everything else is the
    /// synthesized behavior. Encoding stays synthesized and always writes it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        version = try container.decode(Int.self, forKey: .version)
        kind = try container.decode(String.self, forKey: .kind)
        w = try container.decode(Double.self, forKey: .w)
        h = try container.decode(Double.self, forKey: .h)
        flipped = try container.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        fill = try container.decode(String.self, forKey: .fill)
        stroke = try container.decode(String.self, forKey: .stroke)
        strokeWidth = try container.decode(Double.self, forKey: .strokeWidth)
        radius = try container.decode(Double.self, forKey: .radius)
    }

    /// The fill as a color, or nil when the shape has none ("" or an
    /// unparseable string — the latter never survives `decode`).
    var fillColor: NSColor? {
        fill.isEmpty ? nil : TextLayer.color(fromHex: fill)
    }

    /// The stroke as a color, or nil when the shape has none.
    var strokeColor: NSColor? {
        stroke.isEmpty ? nil : TextLayer.color(fromHex: stroke)
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
    /// `type`, an unsupported `version`, an unknown `kind`, a non-finite or
    /// negative measurement, an unparseable color, an all-empty paint, or a
    /// size the kind cannot render all mean "this is a plain raster layer",
    /// never an error and never a crash.
    ///
    /// Per-kind floors: rect/ellipse need a box at least 1 px each way; a
    /// line needs at least one axis ≥ 1 px (an axis-aligned line has a zero
    /// dimension), a stroke width ≥ 1, and a stroke color — a line with no
    /// stroke is nothing.
    static func decode(_ json: String) -> ShapeLayerPayload? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ShapeLayerPayload.self, from: data),
              payload.type == typeName,
              payload.version == currentVersion,
              kinds.contains(payload.kind),
              payload.w.isFinite, payload.w >= 0,
              payload.h.isFinite, payload.h >= 0,
              payload.strokeWidth.isFinite, payload.strokeWidth >= 0, payload.strokeWidth <= 200,
              payload.radius.isFinite, payload.radius >= 0,
              payload.fill.isEmpty || TextLayer.color(fromHex: payload.fill) != nil,
              payload.stroke.isEmpty || TextLayer.color(fromHex: payload.stroke) != nil,
              !payload.fill.isEmpty || !payload.stroke.isEmpty
        else { return nil }
        if payload.kind == "line" {
            guard max(payload.w, payload.h) >= 1, payload.strokeWidth >= 1,
                  !payload.stroke.isEmpty
            else { return nil }
        } else {
            guard payload.w >= 1, payload.h >= 1 else { return nil }
        }
        return payload
    }
}

/// A rendered shape layer: a TIGHT straight-alpha RGBA8 raster (row 0 = top,
/// exactly `width * height * 4` bytes) plus the padding the renderer added
/// around the shape box.
struct ShapeLayerRaster {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    /// Padding added around the shape box on every side; the caller places
    /// the layer at (shapeOrigin − padding) so the shape lands where drawn.
    let padding: Int
}

/// Rendering and naming for shape layers — the one entry point both the shape
/// tools and the agent use, so a layer committed either way looks the same.
enum ShapeLayer {
    // MARK: - Rendering

    /// Rasterizes `payload` tightly: the shape box drawn at `padding(for:)`
    /// inside a raster of `ceil(w) + 2·pad` × `ceil(h) + 2·pad`.
    ///
    /// Rect: a rounded-rect path over the box, radius clamped to half the
    /// shorter side (0 = square corners). Ellipse: the ellipse inscribed in
    /// the box. Both fill first, then stroke centered on the same path. Line:
    /// a single round-capped segment across the box's diagonal — top-left to
    /// bottom-right, or bottom-left to top-right when `flipped` — stroke
    /// only.
    ///
    /// nil for a payload `decode` would refuse (degenerate size for the kind,
    /// nothing visible to paint — a stroke of width 0 counts as nothing) or
    /// a raster beyond the core's pixel cap.
    static func render(_ payload: ShapeLayerPayload) -> ShapeLayerRaster? {
        guard ShapeLayerPayload.kinds.contains(payload.kind),
              payload.w.isFinite, payload.w >= 0, payload.w <= 1e7,
              payload.h.isFinite, payload.h >= 0, payload.h <= 1e7,
              payload.strokeWidth.isFinite, payload.strokeWidth >= 0
        else { return nil }
        let fillColor = payload.fillColor
        // A stroke needs both a color and a width to put ink down; treating
        // width 0 as "no stroke" here keeps `strokePath` and this guard in
        // agreement, so render never returns an all-transparent raster.
        let strokeColor = payload.strokeWidth > 0 ? payload.strokeColor : nil
        if payload.kind == "line" {
            guard max(payload.w, payload.h) >= 1, payload.strokeWidth >= 1,
                  strokeColor != nil
            else { return nil }
        } else {
            guard payload.w >= 1, payload.h >= 1, fillColor != nil || strokeColor != nil
            else { return nil }
        }

        let pad = padding(for: payload)
        let width = Int(ceil(payload.w)) + 2 * pad
        let height = Int(ceil(payload.h)) + 2 * pad
        guard width * height <= RasterImage.maxResizePixels else { return nil }

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
            let box = CGRect(
                x: CGFloat(pad), y: CGFloat(pad),
                width: CGFloat(payload.w), height: CGFloat(payload.h))
            switch payload.kind {
            case "line":
                guard let stroke = strokeColor else { return false }
                context.setStrokeColor(stroke.cgColor)
                context.setLineWidth(CGFloat(payload.strokeWidth))
                context.setLineCap(.round)
                if payload.flipped {
                    context.move(to: CGPoint(x: box.minX, y: box.maxY))
                    context.addLine(to: CGPoint(x: box.maxX, y: box.minY))
                } else {
                    context.move(to: CGPoint(x: box.minX, y: box.minY))
                    context.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                }
                context.strokePath()
            default:
                let path: CGPath
                if payload.kind == "rect" {
                    let radius = min(
                        CGFloat(max(payload.radius, 0)), box.width / 2, box.height / 2)
                    path = radius > 0
                        ? CGPath(
                            roundedRect: box, cornerWidth: radius, cornerHeight: radius,
                            transform: nil)
                        : CGPath(rect: box, transform: nil)
                } else {
                    path = CGPath(ellipseIn: box, transform: nil)
                }
                if let fill = fillColor {
                    context.setFillColor(fill.cgColor)
                    context.addPath(path)
                    context.fillPath()
                }
                if let stroke = strokeColor {
                    context.setStrokeColor(stroke.cgColor)
                    context.setLineWidth(CGFloat(payload.strokeWidth))
                    context.addPath(path)
                    context.strokePath()
                }
            }
            return true
        }
        guard drawn else { return nil }
        Bitmap.unpremultiply(&pixels)
        return ShapeLayerRaster(pixels: pixels, width: width, height: height, padding: pad)
    }

    /// Slack kept around the shape box, in pixels: the stroke is centered on
    /// the path, so half its width lands OUTSIDE the box, plus 2 px so
    /// antialiased edges and round line caps are never clipped —
    /// `ceil(strokeWidth / 2) + 2`, clamped to [2, 128].
    static func padding(for payload: ShapeLayerPayload) -> Int {
        guard payload.strokeWidth.isFinite, payload.strokeWidth > 0 else { return 2 }
        let slack = Int((min(payload.strokeWidth, 300) / 2).rounded(.up)) + 2
        return min(max(slack, 2), 128)
    }

    // MARK: - Naming

    /// The layer name a shape gets, from its kind alone — a shape's styling
    /// makes a poor label, its kind a good one.
    /// Asks whether a destructive edit may drop a layer's shape
    /// description. App-modal for the same reason TextLayer's is: the
    /// asking edit paths are synchronous.
    static func confirmRasterize(layerName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Rasterize shape layer?"
        alert.informativeText =
            "This edit paints over “\(layerName)”, so the layer will no longer be editable "
            + "as a shape: the kind, size, fill, stroke and radius it was rendered from "
            + "are dropped. The pixels themselves are kept."
        alert.addButton(withTitle: "Rasterize")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func layerName(for payload: ShapeLayerPayload) -> String {
        switch payload.kind {
        case "ellipse": return "Ellipse"
        case "line": return "Line"
        default: return "Rectangle"
        }
    }
}

// MARK: - Reading and writing the payload on a document layer

extension RasterDocument {
    /// Layer `idx`'s shape description, or nil when it has none (a plain
    /// raster layer, or metadata this app does not recognize).
    func shapePayload(_ idx: Int) -> ShapeLayerPayload? {
        guard let meta = layerMeta(idx) else { return nil }
        return ShapeLayerPayload.decode(meta)
    }

    /// Attaches `payload` to layer `idx` as its metadata (pure, like every
    /// other layer op — pixels and offset are the caller's to chain).
    func withShapePayload(_ idx: Int, _ payload: ShapeLayerPayload) -> RasterDocument? {
        guard let json = payload.json() else { return nil }
        return withLayerMeta(idx, json)
    }
}
