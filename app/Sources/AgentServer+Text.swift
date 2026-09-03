import AppKit

/// add_text_layer and edit_text_layer: the agent mirrors of the text tool's
/// commit and re-open (EditorViewController+Text.swift commitTextLayer /
/// openTextSession), so a layer made or re-rendered either way is
/// identical: pixels rendered by TextLayer through the layer's description,
/// the description in the layer's meta, the position in the layer's offset
/// (the anchor rule in DescribedLayer.swift — which is what lets Move keep
/// the description honest). Also the text object get_document reports, the
/// typography-argument parser both text tools share (the options bar's
/// knobs and ranges), and the `transform` argument parser the shape tools
/// share.
extension AgentServer {
    /// The family a text layer defaults to: the one the text tool's options
    /// bar starts on, so an agent-made layer looks like a hand-made one.
    /// Falls back to the system font's family when it is not installed.
    static let defaultTextFamily: String = {
        let preferred = "Helvetica Neue"
        if NSFontManager.shared.availableFontFamilies.contains(preferred) { return preferred }
        return NSFont.systemFont(ofSize: 12).familyName ?? preferred
    }()

    /// The `font` argument of the text-layer tools: an installed font
    /// FAMILY, since the description stores a family and rebuilds the face
    /// from it. nil when the caller named none, so the caller can keep what
    /// the layer already says.
    func textFamily(_ a: [String: Any], size: Double) throws -> String? {
        guard let name = stringArg(a, "font") else { return nil }
        guard
            NSFontManager.shared.font(
                withFamily: name, traits: [], weight: 5, size: CGFloat(size)) != nil
        else {
            throw ToolError(
                message: "No font family named \"\(name)\" is installed. A text layer stores a "
                    + "font FAMILY (\"Helvetica Neue\", \"Times New Roman\", …), not a "
                    + "PostScript face name; omit font to keep the current one.")
        }
        return name
    }

    /// The `alignment` argument of the text-layer tools ("left" | "center" |
    /// "right"). nil when the caller named none, so the caller can keep what
    /// the layer already says.
    func textAlignment(_ a: [String: Any]) throws -> String? {
        guard let name = stringArg(a, "alignment") else { return nil }
        guard TextLayerPayload.alignments.contains(name) else {
            throw ToolError(
                message: "alignment must be left, center, or right (got \"\(name)\")")
        }
        return name
    }

    /// The typography arguments both text tools take — `weight`, `italic`,
    /// `underline`, `strikethrough`, `tracking`, `leading`,
    /// `baseline_shift` — laid over `base` (the tool's defaults on add, the
    /// layer's current style on edit): an absent argument keeps base's
    /// value. The ranges are the options bar's own (`TextToolOptions`:
    /// weight 0–15 on the NSFontManager scale, tracking and baseline shift
    /// −100…100 px, leading 0…1000 px), so agent and UI accept exactly the
    /// same values — the rule transform_layer's scale already follows. A
    /// value off its range is refused with the range named rather than
    /// clamped: a silently clamped tracking would leave the reply's text
    /// object disagreeing with what the caller asked for.
    func textStyleArgs(_ a: [String: Any], base: TextStyle) throws -> TextStyle {
        var style = base
        if let raw = a["weight"], !(raw is NSNull) {
            let range = TextToolOptions.weightRange
            guard let weight = intArg(a, "weight"), range.contains(weight) else {
                throw ToolError(
                    message: "weight must be an integer \(range.lowerBound)-\(range.upperBound) "
                        + "on the NSFontManager scale (3 light, 5 regular, 6 medium, "
                        + "8 semibold, 9 bold)")
            }
            style.weight = weight
        }
        style.italic = try textFlagArg(a, "italic") ?? base.italic
        style.underline = try textFlagArg(a, "underline") ?? base.underline
        style.strikethrough = try textFlagArg(a, "strikethrough") ?? base.strikethrough
        style.tracking =
            try textMetricArg(a, "tracking", range: TextToolOptions.trackingRange)
            ?? base.tracking
        style.leading =
            try textMetricArg(a, "leading", range: TextToolOptions.leadingRange) ?? base.leading
        style.baselineShift =
            try textMetricArg(a, "baseline_shift", range: TextToolOptions.baselineShiftRange)
            ?? base.baselineShift
        return style
    }

    /// A boolean typography flag: nil when absent (JSON null reads as
    /// absent, as every argument helper treats it); anything that is not a
    /// boolean or its string spelling is refused by name, so a mistyped
    /// `"italic": "yes"` cannot pass as "keep".
    private func textFlagArg(_ a: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = a[key], !(raw is NSNull) else { return nil }
        guard let flag = boolArg(a, key) else {
            throw ToolError(message: "\(key) must be true or false")
        }
        return flag
    }

    /// A typography measure in px: nil when absent (or JSON null); refused
    /// by name when it is not a finite number inside `range` (a JSON
    /// boolean included — it would read as 1 or 0).
    private func textMetricArg(
        _ a: [String: Any], _ key: String, range: ClosedRange<Double>
    ) throws -> Double? {
        guard let raw = a[key], !(raw is NSNull) else { return nil }
        guard !Self.isJSONBoolean(raw), let value = doubleArg(a, key), value.isFinite,
              range.contains(value)
        else {
            throw ToolError(
                message: "\(key) must be a number between \(Int(range.lowerBound)) and "
                    + "\(Int(range.upperBound)) px")
        }
        return value
    }

    /// The `wrap_width` argument as a box: absent (or JSON null) → nil, the
    /// caller defaults it; 0 → point text that never wraps; a finite width
    /// ≥ 1 → paragraph text wrapping there, capped at the editor's own
    /// `TextLayer.maxBoxWidth` so the two sides store the same width.
    /// Refused by name — like every typography argument — when it is
    /// present but not a number: a JSON boolean (which reads as 1 or 0
    /// through NSNumber, and would silently make a 1 px box or point text)
    /// or a string that does not parse (which would silently take the
    /// default).
    func textBoxArg(_ a: [String: Any]) throws -> TextBox? {
        guard let raw = a["wrap_width"], !(raw is NSNull) else { return nil }
        let usage =
            "wrap_width must be a number: 0 (point text that never wraps) or a width of at "
            + "least 1 px"
        guard !Self.isJSONBoolean(raw), let given = doubleArg(a, "wrap_width"), given.isFinite
        else { throw ToolError(message: usage) }
        if given == 0 { return .point }
        guard given >= 1 else { throw ToolError(message: usage) }
        return .width(min(given, TextLayer.maxBoxWidth))
    }

    /// Whether a decoded JSON value is a boolean: JSONSerialization hands
    /// `true`/`false` over as CFBoolean, which bridges to NSNumber and so
    /// passes every numeric helper as 1/0. (`raw is Bool` would not do: the
    /// number 1 bridges to Bool too.)
    static func isJSONBoolean(_ raw: Any) -> Bool {
        guard let number = raw as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// The `size` argument, clamped to the catalog's 4…1000 px as before;
    /// nil when absent (or JSON null). Refused by name when present but not
    /// a finite number: `"nan"` parses as a Double, min/max pass NaN
    /// through, NSFontManager answers it with a 12 pt face, and the
    /// renderer's integer padding would then trap on it — taking the
    /// user's unsaved document down with the app.
    func textSizeArg(_ a: [String: Any]) throws -> Double? {
        guard let raw = a["size"], !(raw is NSNull) else { return nil }
        guard !Self.isJSONBoolean(raw), let size = doubleArg(a, "size"), size.isFinite else {
            throw ToolError(message: "size must be a number of px (4-1000)")
        }
        return min(max(size, 4), 1000)
    }

    /// The `transform` argument: exactly four finite numbers (or their
    /// string spellings), row-major — (x, y) ↦ (a·x + b·y, c·x + d·y), the
    /// wire order `LinearMap(array:)` transposes — with |det| ≥ 1e-9 (the
    /// core's own singularity floor); nil when absent or JSON null (the
    /// "keep" / "default" every other optional argument here reads null
    /// as); ToolError otherwise.
    func linearMapArg(_ a: [String: Any], _ key: String) throws -> LinearMap? {
        guard let raw = a[key], !(raw is NSNull) else { return nil }
        let usage =
            "\(key) must be four numbers [a, b, c, d], row-major — (x, y) maps to "
            + "(a·x + b·y, c·x + d·y); [1, 0, 0, 1] is the identity and a clockwise "
            + "rotation by θ is [cos θ, -sin θ, sin θ, cos θ]."
        guard let elements = raw as? [Any], elements.count == 4 else {
            throw ToolError(message: usage)
        }
        let numbers = elements.compactMap { Self.finiteNumber($0) }
        guard numbers.count == 4, let map = LinearMap(array: numbers) else {
            throw ToolError(message: usage)
        }
        guard map.isInvertible else {
            throw ToolError(
                message: "\(key) is singular (its determinant is ~0, so the layer would "
                    + "collapse to a line); use a map with |a·d − b·c| ≥ 1e-9.")
        }
        return map
    }

    /// The text object get_document and the text tools report: every field
    /// of the description, `box_width` as a number for paragraph text, 0 for
    /// point text and null for a legacy layer whose width was never stored,
    /// `transform` row-major (`LinearMap.array`), and `origin` — the exact
    /// canvas position of the text block's top-left (fractional after a
    /// transform) — when the anchor is known.
    static func textFields(_ payload: TextLayerPayload, anchor: CGPoint?) -> [String: Any] {
        let boxWidth: Any
        switch payload.box {
        case .unspecified: boxWidth = NSNull()
        case .point: boxWidth = 0
        case let .width(width): boxWidth = width
        }
        var fields: [String: Any] = [
            "string": payload.string,
            "font": payload.font,
            "size": payload.size,
            "color": payload.color,
            "alignment": payload.alignment,
            "weight": payload.weight,
            "italic": payload.italic,
            "tracking": payload.tracking,
            "leading": payload.leading,
            "baseline_shift": payload.baselineShift,
            "underline": payload.underline,
            "strikethrough": payload.strikethrough,
            "box_width": boxWidth,
            "transform": payload.transform.array,
        ]
        if let anchor = anchor {
            fields["origin"] = ["x": Double(anchor.x), "y": Double(anchor.y)]
        }
        return fields
    }

    /// What a text-layer tool reports back: where the layer landed (the ink
    /// box plus a few px of slack for antialiasing and glyph overhang, so
    /// these are the layer's real bounds as get_document reports them) and
    /// the description it is now rendered from.
    func textLayerResult(
        layer: Int, name: String, payload: TextLayerPayload, document: ImageDocument
    ) throws -> String {
        let info = document.doc?.layerInfo(layer)
        return try jsonResult([
            "ok": true,
            "layer": layer,
            "name": name,
            "bounds": [
                "x": info?.offsetX ?? 0, "y": info?.offsetY ?? 0,
                "width": info?.width ?? 0, "height": info?.height ?? 0,
            ],
            "text": Self.textFields(payload, anchor: document.doc?.describedAnchor(layer)),
            "note": "Re-editable: change it with edit_text_layer; transform_layer composes "
                + "into it. Painting on this layer (brush, eraser, fill, gradient, add_text, "
                + "apply_filter) drops the text and leaves plain pixels.",
        ])
    }

    /// Creates a RE-EDITABLE text layer above the active one: the string,
    /// font, size, color, alignment, typography and transform become the
    /// layer's description and the pixels are only their rendering. Mirrors
    /// the text tool's own commit (EditorViewController+Text.swift
    /// commitTextLayer) so both paths produce identical layers.
    func addTextLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let text = try requiredString(a, "text")
        guard let x = doubleArg(a, "x"), let y = doubleArg(a, "y"), x.isFinite, y.isFinite
        else {
            throw ToolError(
                message: "add_text_layer requires x and y (the top-left of the text block), "
                    + "finite numbers")
        }
        let size = try textSizeArg(a) ?? 48
        let family = try textFamily(a, size: size) ?? Self.defaultTextFamily
        let color = try parseColor(a, "color", fallback: .black)
        let alignment = try textAlignment(a) ?? "left"
        let transform = try linearMapArg(a, "transform") ?? .identity
        // The box: wrap_width, or from the block's left edge to the canvas's
        // right edge — the same default add_text uses.
        let box = try textBoxArg(a) ?? .width(max(Double(doc.width) - x, 10))
        // Typography over the tool's defaults (regular weight, no tracking,
        // natural line height…) — the same defaults the options bar starts
        // on, so an argument-free call still looks like a hand-made layer.
        let style = try textStyleArgs(a, base: TextStyle(family: family, size: size))
        var payload = TextLayerPayload(
            string: text, style: style, color: color, box: box, transform: transform)
        payload.alignment = alignment
        // Whole pixels for an untransformed block, exact otherwise — the
        // placement rule every interactive commit follows.
        let anchor = DescribedLayer.placementAnchor(CGPoint(x: x, y: y), transform: transform)
        let below = document.activeLayerIndex
        let name = TextLayer.layerName(for: text)
        do {
            try performGroupedEdit(document, "Add Text Layer") {
                $0.addingDescribedLayer(above: below, .text(payload), anchor: anchor, name: name)
            }
        } catch is ToolError {
            // The op is nil exactly when the render is: name the inputs.
            throw ToolError(
                message: "Could not lay the text out — check that text is not empty and that "
                    + "x, y, size, wrap_width, tracking, leading and transform are sane "
                    + "numbers (a huge scale would pass the core's 100 megapixel ceiling for "
                    + "one layer).")
        }
        let index = min(below + 1, (document.doc?.layerCount ?? 1) - 1)
        document.activeLayerIndex = index
        // The edit's own notification went out before the active layer
        // moved, so the panel and status bar need this one to catch up.
        NotificationCenter.default.post(
            name: .imageDocumentImageDidChange, object: document, userInfo: ["isLive": false])
        return try textLayerResult(layer: index, name: name, payload: payload, document: document)
    }

    /// Re-renders an existing text layer from a changed description: any
    /// field the call omits keeps the value the layer already carries, the
    /// block is re-laid-out from its own origin (the anchor), and the layer's
    /// transform is kept unless a new one is passed. Pixels, offset,
    /// description and — re-cropped to the new rect — the mask are replaced
    /// in one undo step. Mirrors the layers panel's double-click re-edit
    /// (EditorViewController+Text.swift commitTextLayer, editing branch).
    func editTextLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard let info = doc.layerInfo(index) else {
            throw ToolError(message: "Layer \(index) could not be read")
        }
        guard let current = doc.textPayload(index) else {
            throw ToolError(
                message: "Layer \(index) (\"\(info.name)\") is not a text layer — it is plain "
                    + "pixels with no text to re-render (get_document reports a \"text\" "
                    + "object on the layers that have one). Make re-editable text with "
                    + "add_text_layer, or paint characters onto this layer with add_text.")
        }
        guard let anchor = doc.describedAnchor(index) else {
            throw ToolError(
                message: "Layer \(index)'s text description has no recoverable position; "
                    + "re-create it with add_text_layer.")
        }
        let text = stringArg(a, "text") ?? current.string
        guard !text.isEmpty else {
            throw ToolError(
                message: "text cannot be empty; remove the layer with delete_layer instead.")
        }
        let size = try textSizeArg(a) ?? current.size
        let family = try textFamily(a, size: size) ?? current.font
        let color = try parseColor(a, "color", fallback: current.nsColor)
        let alignment = try textAlignment(a) ?? current.alignment
        let transform = try linearMapArg(a, "transform") ?? current.transform
        // The box: wrap_width, else the layer's stored box; a layer saved
        // before widths were stored re-wraps at this tool's own pre-change
        // default (from its origin to the canvas's right edge) and stores
        // that width from now on.
        let box = try textBoxArg(a)
            ?? (current.box == .unspecified
                ? .width(max(Double(doc.width) - Double(anchor.x), 10)) : current.box)
        // Typography over the layer's CURRENT style: an absent argument
        // keeps what the layer carries, exactly as text, font and size do.
        var base = current.style
        base.family = family
        base.size = size
        let style = try textStyleArgs(a, base: base)
        var payload = TextLayerPayload(
            string: text, style: style, color: color, box: box, transform: transform)
        payload.alignment = alignment
        let name = TextLayer.layerName(for: text)
        // The name follows the text only while it still IS the text: a name
        // somebody typed themselves survives the re-render.
        let nameFollowsText = info.name == TextLayer.layerName(for: current.string)
        do {
            try performGroupedEdit(document, "Edit Text Layer") { doc in
                guard let described = doc.rerenderingDescribedLayer(
                    index, .text(payload), anchor: anchor)
                else { return nil }
                guard nameFollowsText else { return described }
                return described.withLayerName(index, name) ?? described
            }
        } catch is ToolError {
            throw ToolError(
                message: "Could not lay the text out — check size, wrap_width, tracking, "
                    + "leading and transform.")
        }
        return try textLayerResult(
            layer: index, name: nameFollowsText ? name : info.name, payload: payload,
            document: document)
    }
}
