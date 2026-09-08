import Foundation

/// The app-side mirror of the core's meta schema (the table in
/// core/src/adjust.rs's module doc) for the phase-5 adjustment ops: every
/// parameter's key, kind, range and default, in ONE place, so the MCP
/// validator's refusals, the sheets' clamps and the catalog prose cannot
/// drift apart.
///
/// The legacy nine ops are deliberately NOT here — their validation stays
/// where it is (`AgentServer.adjustmentParams`), which is also why
/// `op(forFilter:)` returns nil for "levels", "posterize" and friends: their
/// flat-argument `apply_filter` path must keep working exactly as it does.
///
/// Two conventions the whole table follows, stated once:
///
/// - **Values are the core's units, not the dialog's.** Gains, amounts and
///   ink nudges are unit floats (Photoshop's percentages over 100); angles
///   and hues are degrees; radii are pixels; temperature is kelvin. A sheet
///   that shows percent divides by 100 on write.
/// - **A colour is the DOCUMENT's numbers**, like an eyedropper sample, not
///   an authored sRGB colour (`AdjustmentColor`). Only its spelling is
///   checked here; nothing converts.
enum AdjustmentSchema {
    /// One parameter's kind. `.object` nests (a colour-balance tone block, a
    /// mixer row, one hue band), which is what lets one table describe every
    /// op the core parses.
    enum Kind {
        /// Range, then the value an absent key takes.
        case number(ClosedRange<Double>, Double)
        /// Range, then the default — nil for a REQUIRED key.
        case integer(ClosedRange<Double>, Double?)
        case boolean(Bool)
        /// `"#rrggbb"` default, in the document's numbers.
        case color(String)
        /// Allowed strings, then the default — nil for a REQUIRED key.
        case choice([String], String?)
        /// A nested `{...}` object with its own parameters.
        case object([Param])
        /// A fixed-length array of numbers, all inside one range.
        case numbers(count: Int, ClosedRange<Double>, [Double])
        /// The layer-style gradient object (`stops`, `reverse`, …), whose
        /// stop colours here are the document's numbers.
        case gradient
        /// A REQUIRED base64 string of little-endian f32 — a LUT's table.
        /// Its length is checked against `size` in `validate`'s tail, which
        /// is the one rule a per-key table cannot express.
        case lutTable
        /// An optional display-only string, at most `maxChars` characters
        /// (the LUT title). Its own kind rather than a `.choice` because the
        /// value set is open.
        case text(maxChars: Int)
    }

    struct Param {
        let key: String
        let kind: Kind

        init(_ key: String, _ kind: Kind) {
            self.key = key
            self.kind = kind
        }
    }

    // MARK: - The table

    /// The six hue bands, in the order Photoshop's range popup lists them —
    /// the same order the core's `HUE_WHEEL` uses, so a band's index is its
    /// default centre over 60 degrees.
    static let hueBands = ["reds", "yellows", "greens", "cyans", "blues", "magentas"]

    /// Selective Color's nine ranges: the six hues, then the three
    /// achromatic ones.
    static let selectiveRanges = hueBands + ["whites", "neutrals", "blacks"]

    /// Black & White's factory mix, in `hueBands` order.
    static let blackAndWhiteDefaults: [Double] = [0.4, 0.6, 0.4, 0.6, 0.2, 0.8]

    /// The sRGB spelling of Photoshop's Warming Filter (85) — the core's
    /// fallback when `photo_filter` omits `color`. A sheet writes the
    /// DOCUMENT's spelling of it instead
    /// (`AdjustmentColor.documentHex(forSRGBHex:in:)`).
    static let warming85 = "#ec8a00"

    /// The sRGB spelling of the Black & White tint default (hue 42°,
    /// saturation 20 %), with the same caveat as `warming85`.
    static let blackAndWhiteTint = "#998a66"

    /// This build's LUT storage caps, mirrored from `adjust_lut`: a bigger
    /// .cube is resampled down to them by `rz_lut_parse_cube`.
    static let maxLUT1D = 1024.0
    static let maxLUT3D = 33.0
    /// The largest size a FILE may declare, which is what `source_size`
    /// reports after a resample.
    static let maxLUTSource = 65536.0

    /// The widest a LUT domain corner may be. `adjust_lut::triple` narrows
    /// both corners to `f32` and refuses a non-finite one, so the bound is
    /// the largest finite Float — a Double beyond it would pass a check in
    /// double precision and become an infinity in the core, which refuses
    /// the whole meta and leaves an inert raster layer behind an `ok: true`.
    static let maxLUTDomain = Double(Float.greatestFiniteMagnitude)

    /// Every parameter of `op`, or [] for the legacy nine.
    static func params(for op: AdjustmentLayerOp) -> [Param] {
        switch op {
        case .exposure:
            return [
                Param("exposure", .number(-20...20, 0)),
                Param("offset", .number(-0.5...0.5, 0)),
                // Photoshop's EXPOSURE gamma: applied as a power, so above
                // 1 darkens — the inverse of `levels`' midtone gamma.
                Param("gamma", .number(0.01...9.99, 1)),
            ]
        case .vibrance:
            return [
                Param("vibrance", .number(-1...1, 0)),
                Param("saturation", .number(-1...1, 0)),
            ]
        case .hueSaturation:
            let band: (Int) -> Kind = { index in
                .object([
                    Param("hue", .number(-180...180, 0)),
                    Param("saturation", .number(-1...1, 0)),
                    Param("lightness", .number(-1...1, 0)),
                    Param("center", .number(0...360, 60 * Double(index))),
                    Param("inner", .number(0...180, 15)),
                    Param("falloff", .number(0...180, 30)),
                ])
            }
            return [
                Param("hue", .number(-180...180, 0)),
                Param("saturation", .number(-1...1, 0)),
                Param("lightness", .number(-1...1, 0)),
                Param("bands", .object(hueBands.enumerated().map {
                    Param($0.element, band($0.offset))
                })),
                Param("colorize", .boolean(false)),
                Param("colorize_hue", .number(0...360, 0)),
                Param("colorize_saturation", .number(0...1, 0.25)),
                Param("colorize_lightness", .number(-1...1, 0)),
            ]
        case .colorBalance:
            let tone = Kind.object([
                Param("cyan_red", .number(-1...1, 0)),
                Param("magenta_green", .number(-1...1, 0)),
                Param("yellow_blue", .number(-1...1, 0)),
            ])
            return [
                Param("shadows", tone),
                Param("midtones", tone),
                Param("highlights", tone),
                Param("preserve_luminosity", .boolean(true)),
            ]
        case .blackAndWhite:
            return zip(hueBands, blackAndWhiteDefaults).map {
                Param($0, .number(-2...3, $1))
            } + [
                Param("tint", .boolean(false)),
                Param("tint_color", .color(blackAndWhiteTint)),
            ]
        case .photoFilter:
            return [
                Param("color", .color(warming85)),
                Param("density", .number(0...1, 0.25)),
                Param("preserve_luminosity", .boolean(true)),
            ]
        case .channelMixer:
            let row: ([Double]) -> Kind = { defaults in
                .object([
                    Param("r", .number(-2...2, defaults[0])),
                    Param("g", .number(-2...2, defaults[1])),
                    Param("b", .number(-2...2, defaults[2])),
                    Param("constant", .number(-2...2, defaults[3])),
                ])
            }
            return [
                Param("monochrome", .boolean(false)),
                Param("red", row([1, 0, 0, 0])),
                Param("green", row([0, 1, 0, 0])),
                Param("blue", row([0, 0, 1, 0])),
                Param("gray", row([0.4, 0.4, 0.2, 0])),
            ]
        case .selectiveColor:
            let inks = Kind.object([
                Param("c", .number(-1...1, 0)),
                Param("m", .number(-1...1, 0)),
                Param("y", .number(-1...1, 0)),
                Param("k", .number(-1...1, 0)),
            ])
            return [Param("method", .choice(["relative", "absolute"], "relative"))]
                + selectiveRanges.map { Param($0, inks) }
        case .shadowsHighlights:
            let band: (Double) -> Kind = { amount in
                .object([
                    Param("amount", .number(0...1, amount)),
                    Param("tone", .number(0.01...1, 0.5)),
                ])
            }
            return [
                Param("shadows", band(0.35)),
                Param("highlights", band(0)),
                Param("radius", .number(0...1000, 30)),
                Param("color", .number(-1...1, 0.2)),
                Param("midtone_contrast", .number(-1...1, 0)),
            ]
        case .whiteBalance:
            return [
                Param("temperature", .number(1667...25000, 6504)),
                Param("tint", .number(-150...150, 0)),
            ]
        case .gradientMap:
            return [
                Param("gradient", .gradient),
                Param("dither", .boolean(true)),
            ]
        case .colorLookup:
            return [
                Param("kind", .choice(["1d", "3d"], nil)),
                // The widest storage cap; the 3D cap of 33 is enforced in
                // the tail, where `kind` is known.
                Param("size", .integer(2...maxLUT1D, nil)),
                Param("table", .lutTable),
                // Optional, and its effective default is `size` — the core
                // fills that in, so nothing is written here; it exists so a
                // resampled LUT's own size survives every round trip.
                Param("source_size", .integer(2...maxLUTSource, nil)),
                // Any finite f32, which is the core's only constraint on a
                // .cube's domain corners.
                Param("domain_min", .numbers(count: 3, -maxLUTDomain...maxLUTDomain, [0, 0, 0])),
                Param("domain_max", .numbers(count: 3, -maxLUTDomain...maxLUTDomain, [1, 1, 1])),
                Param("strength", .number(0...1, 1)),
                Param("title", .text(maxChars: 128)),
            ]
        case .bcs, .curves, .levels, .hueRotate, .posterize, .threshold,
            .invert, .grayscale, .sepia:
            return []
        }
    }

    /// The phase-5 op an `apply_filter` `filter` names, or nil for the
    /// legacy filters — which keep their flat arguments and their
    /// hand-written arms, untouched by this table.
    static func op(forFilter filter: String) -> AdjustmentLayerOp? {
        guard let op = AdjustmentLayerOp(rawValue: filter), !params(for: op).isEmpty else {
            return nil
        }
        return op
    }

    /// Top-level keys `op` accepts, plus its input-only aliases —
    /// `color_lookup`'s `file`, an absolute .cube path this app parses and
    /// expands into the stored form. Sorted, because the refusals list it.
    static func inputKeys(for op: AdjustmentLayerOp) -> [String] {
        var keys = params(for: op).map { $0.key }
        if op == .colorLookup { keys.append("file") }
        return keys.sorted()
    }

    /// The op's defaults as a params object — what a NEW layer starts from.
    ///
    /// Nested blocks are deliberately omitted: the core reads an absent
    /// block as exactly that block's defaults, so writing them out would
    /// only make the meta (which travels in `.rz` and in every
    /// `get_document` reply) longer for the same pixels. A sheet prefilling
    /// controls for a block its layer omits reads `objectDefaults(for:path:)`.
    ///
    /// `color_lookup` has no complete default — `kind`, `size` and `table`
    /// are required — so it starts as the domain corners and `strength`
    /// alone, and its sheet must load a .cube before there is anything to
    /// apply.
    static func defaults(for op: AdjustmentLayerOp) -> [String: Any] {
        var out: [String: Any] = [:]
        for param in params(for: op) {
            switch param.kind {
            case .number(_, let value): out[param.key] = value
            case .integer(_, let value): if let value = value { out[param.key] = Int(value) }
            case .boolean(let value): out[param.key] = value
            case .color(let hex): out[param.key] = hex
            case .choice(_, let value): if let value = value { out[param.key] = value }
            case .numbers(_, _, let values): out[param.key] = values
            case .gradient: out[param.key] = defaultGradient
            case .object, .lutTable, .text: break
            }
        }
        return out
    }

    /// Whether two params objects describe the SAME adjustment — the same
    /// pixels, whatever the two spell out and whatever they leave to a
    /// default. What "Apply changed nothing, so commit nothing" must mean.
    ///
    /// A byte comparison of the two metas is NOT that test, and using one
    /// is a bug: a sheet writes every key it has a control for, while a
    /// layer authored over MCP, by an older build or read from a `.rz`
    /// stores only the keys its caller passed. So opening Adjustment
    /// Options… on a layer whose params are `{"exposure": 1}` and pressing
    /// Apply without touching a control produced
    /// `{"exposure": 1, "gamma": 1, "offset": 0}` — a different string for
    /// an identical picture — and registered an undo step and a dirty flag
    /// for an edit that moved no pixel.
    static func sameEffect(
        _ a: [String: Any], _ b: [String: Any], for op: AdjustmentLayerOp
    ) -> Bool {
        let lhs = AdjustmentLayerPayload(op: op, params: effective(a, for: op)).json()
        let rhs = AdjustmentLayerPayload(op: op, params: effective(b, for: op)).json()
        return lhs != nil && lhs == rhs
    }

    /// `params` reduced to WHAT THE OP READS, every value made explicit: a
    /// key the object omits takes its schema default, a nested block it
    /// omits is filled with that block's defaults, numbers are normalized to
    /// one JSON spelling, and a key the op does not read at all is dropped
    /// (the core ignores those, so they are not part of the adjustment).
    ///
    /// A key that IS read but holds the wrong JSON type is carried through
    /// as it stands rather than replaced by its default, so a malformed
    /// value never compares equal to the value that would repair it.
    ///
    /// The legacy nine have no table, and answer with `params` untouched —
    /// their dialogs are `AdjustmentLayerSheetController`'s and write the
    /// keys they read, so a byte comparison was already right for them.
    static func effective(
        _ params: [String: Any], for op: AdjustmentLayerOp
    ) -> [String: Any] {
        effective(params, table: self.params(for: op))
    }

    private static func effective(
        _ params: [String: Any], table: [Param]
    ) -> [String: Any] {
        guard !table.isEmpty else { return params }
        var out: [String: Any] = [:]
        for param in table {
            let raw = params[param.key]
            switch param.kind {
            case .number(_, let value):
                out[param.key] = (raw as? NSNumber)?.doubleValue ?? raw ?? value
            case .integer(_, let value):
                if let n = (raw as? NSNumber)?.intValue {
                    out[param.key] = n
                } else if let raw = raw {
                    out[param.key] = raw
                } else if let value = value {
                    out[param.key] = Int(value)
                }
            case .boolean(let value):
                out[param.key] = (raw as? Bool) ?? raw ?? value
            case .color(let hex):
                out[param.key] = (raw as? String).flatMap(normalizedHex) ?? raw ?? hex
            case .choice(_, let value):
                if let raw = raw {
                    out[param.key] = raw
                } else if let value = value {
                    out[param.key] = value
                }
            case .numbers(_, _, let values):
                if let list = raw as? [Any] {
                    out[param.key] = list.map { ($0 as? NSNumber)?.doubleValue ?? Double.nan }
                } else {
                    out[param.key] = raw ?? values
                }
            case .object(let inner):
                out[param.key] = effective(raw as? [String: Any] ?? [:], table: inner)
            case .gradient:
                out[param.key] = effectiveGradient(raw)
            case .lutTable, .text:
                // No default: present or absent is the whole story, and the
                // table's base64 is compared as it stands.
                if let raw = raw { out[param.key] = raw }
            }
        }
        return out
    }

    /// The gradient keys a `gradient_map` READS — the stops and `reverse`.
    /// The geometry a layer style's gradient also carries (`style`, `angle`,
    /// `scale`, `align_with_layer`) is accepted and ignored by the op, which
    /// is why `GradientFill.mapParams` does not write it and why it plays no
    /// part in whether the adjustment changed.
    ///
    /// An ABSENT `gradient`, and a gradient object with no `stops`, are the
    /// core's own black→white ramp: `style_json::gradient` substitutes
    /// `GradientFill::default()` for both, so `add_adjustment_layer
    /// {"op":"gradient_map"}` renders exactly like the same layer written
    /// out in full. They therefore resolve to `defaultGradient`'s stops
    /// here too — the missing fallback was the one case `sameEffect` got
    /// wrong, and it was the phantom undo step that method exists to stop.
    ///
    /// Anything else under either key is MALFORMED — the core refuses the
    /// whole meta and the layer composites as plain raster, which is not the
    /// picture any ramp describes — so it is carried through as it stands,
    /// per this file's rule that a malformed value never compares equal to
    /// the value that would repair it.
    ///
    /// The stops come back in POSITION order, ties broken by the incoming
    /// order — the stable sort `style_json::gradient` does at parse time
    /// (`stops.sort_by(total_cmp)`) and `GradientEditorView.sortedStops`
    /// mirrors on the way into the strip. Order is therefore not part of the
    /// picture, and comparing it as if it were was a second phantom undo
    /// step: a layer authored over MCP as `[white@1, black@0]` renders as
    /// the ordinary black→white ramp, so re-opening it and pressing Apply —
    /// which reads the stops back through the editor, sorted — must commit
    /// nothing.
    private static func effectiveGradient(_ value: Any?) -> Any {
        if let value = value, !(value is [String: Any]) { return value }
        let object = (value as? [String: Any]) ?? [:]
        let list: [Any]
        if let declared = object["stops"] {
            guard let array = declared as? [Any] else { return object }
            list = array
        } else {
            list = defaultGradient["stops"] as? [Any] ?? []
        }
        let stops = list.map { entry -> (order: Double, stop: [String: Any]) in
            let stop = entry as? [String: Any] ?? [:]
            let position = (stop["position"] as? NSNumber)?.doubleValue ?? 0
            // A non-finite position sorts as 0 rather than poisoning the
            // ordering, which Swift's sort is entitled to answer with
            // anything at all: it is kept verbatim in the stop itself, where
            // it makes the payload unencodable and so still compares unequal.
            return (position.isFinite ? position : 0, [
                "position": position,
                "color": (stop["color"] as? String).flatMap(normalizedHex) ?? "#000000",
                "opacity": (stop["opacity"] as? NSNumber)?.doubleValue ?? 1,
            ])
        }
        let sorted = stops.enumerated().sorted { a, b in
            a.element.order == b.element.order
                ? a.offset < b.offset
                : a.element.order < b.element.order
        }
        return [
            "stops": sorted.map { $0.element.stop },
            "reverse": (object["reverse"] as? Bool) ?? false,
        ]
    }

    /// A Gradient Map's starting ramp: black to white, the identity map from
    /// luma to grey. Only `stops` and `reverse` are written — the geometry
    /// keys a layer style's gradient carries mean nothing to a map, and the
    /// core accepts and ignores them.
    static let defaultGradient: [String: Any] = [
        "stops": [
            ["position": 0.0, "color": "#000000", "opacity": 1.0],
            ["position": 1.0, "color": "#ffffff", "opacity": 1.0],
        ],
        "reverse": false,
    ]

    /// The defaults of the nested block at `path` (`["shadows"]`,
    /// `["bands", "reds"]`), for a sheet prefilling controls the layer's
    /// params leave out. [:] when the op has no such block.
    static func objectDefaults(for op: AdjustmentLayerOp, path: [String]) -> [String: Any] {
        var list = params(for: op)
        var remaining = path[...]
        while let key = remaining.first {
            remaining = remaining.dropFirst()
            guard let found = list.first(where: { $0.key == key }),
                  case .object(let inner) = found.kind
            else { return [:] }
            if remaining.isEmpty {
                var out: [String: Any] = [:]
                for param in inner {
                    switch param.kind {
                    case .number(_, let value): out[param.key] = value
                    case .integer(_, let value):
                        if let value = value { out[param.key] = Int(value) }
                    case .boolean(let value): out[param.key] = value
                    case .color(let hex): out[param.key] = hex
                    case .choice(_, let value): if let value = value { out[param.key] = value }
                    case .numbers(_, _, let values): out[param.key] = values
                    case .gradient: out[param.key] = defaultGradient
                    case .object, .lutTable, .text: break
                    }
                }
                return out
            }
            list = inner
        }
        return [:]
    }

    // MARK: - Validation

    private static func fail(_ message: String) -> AgentServer.ToolError {
        AgentServer.ToolError(message: message)
    }

    /// Validates `params` against the table, throwing a message that names
    /// the offending key and its range (the MCP contract), and returning the
    /// params NORMALIZED — numbers as numbers, booleans as booleans,
    /// `color_lookup`'s `file` already expanded into the stored table.
    ///
    /// Normalizing is not cosmetic: the core's parse is typed (a boolean
    /// spelled `"true"` makes the whole meta malformed and the layer
    /// silently composites as plain raster), so what this returns is what
    /// gets stored.
    static func validate(
        _ params: [String: Any], for op: AdjustmentLayerOp
    ) throws -> [String: Any] {
        let table = self.params(for: op)
        guard !table.isEmpty else { return params }
        var source = params
        // color_lookup's one input-only key: an absolute .cube path the app
        // parses through the core, whose output REPLACES the table keys.
        if op == .colorLookup, let raw = source.removeValue(forKey: "file") {
            guard let path = raw as? String, !path.isEmpty else {
                throw fail("file must be a path to a .cube LUT")
            }
            switch RasterLUT.parseCube(path: path) {
            case .failure(let error):
                throw fail(error.message)
            case .success(let parsed):
                let strength = source["strength"]
                for key in ["kind", "size", "table", "source_size", "domain_min",
                            "domain_max", "title", "strength"] {
                    source.removeValue(forKey: key)
                }
                guard source.isEmpty else {
                    throw fail(unknownKeyMessage(op, Array(source.keys).sorted()))
                }
                source = parsed
                if let strength = strength { source["strength"] = strength }
            }
        }
        let known = Set(table.map { $0.key })
        let unknown = source.keys.filter { !known.contains($0) }.sorted()
        if !unknown.isEmpty { throw fail(unknownKeyMessage(op, unknown)) }

        var out: [String: Any] = [:]
        for param in table {
            guard let value = source[param.key] else { continue }
            out[param.key] = try checked(value, param.kind, param.key, op)
        }
        try tail(op, &out)
        return out
    }

    private static func unknownKeyMessage(
        _ op: AdjustmentLayerOp, _ unknown: [String]
    ) -> String {
        "Unknown \(op.rawValue) parameter \"\(unknown[0])\" — \(op.rawValue) takes "
            + inputKeys(for: op).joined(separator: ", ") + "."
    }

    /// One value against one kind, returning the normalized form.
    private static func checked(
        _ value: Any, _ kind: Kind, _ path: String, _ op: AdjustmentLayerOp
    ) throws -> Any {
        switch kind {
        case .number(let range, _):
            return try number(value, range, path)
        case .integer(let range, _):
            let n = try number(value, range, path)
            guard n == n.rounded() else {
                throw fail("\(path) must be a whole number (got \(n))")
            }
            return Int(n)
        case .boolean:
            if let flag = value as? Bool { return flag }
            if let text = value as? String, text == "true" || text == "false" {
                return text == "true"
            }
            throw fail("\(path) must be true or false")
        case .color:
            guard let text = value as? String, let hex = normalizedHex(text) else {
                throw fail("\(path) must be a colour like \"#7f3f00\" — an adjustment's "
                    + "colour is in the document's own numbers, not sRGB")
            }
            return hex
        case .choice(let allowed, _):
            guard let text = value as? String, allowed.contains(text) else {
                throw fail("\(path) must be one of " + allowed.joined(separator: ", "))
            }
            return text
        case .object(let inner):
            guard let dict = value as? [String: Any] else {
                throw fail("\(path) must be an object, e.g. "
                    + "{\"\(inner.first?.key ?? "amount")\": 0.5}")
            }
            let known = Set(inner.map { $0.key })
            let unknown = dict.keys.filter { !known.contains($0) }.sorted()
            if let first = unknown.first {
                throw fail("Unknown \(path) parameter \"\(first)\" — \(path) takes "
                    + inner.map { $0.key }.joined(separator: ", ") + ".")
            }
            var out: [String: Any] = [:]
            for param in inner {
                guard let sub = dict[param.key] else { continue }
                out[param.key] = try checked(sub, param.kind, "\(path).\(param.key)", op)
            }
            return out
        case .numbers(let count, let range, _):
            guard let list = value as? [Any], list.count == count else {
                throw fail("\(path) must be an array of \(count) numbers")
            }
            return try list.map { try number($0, range, path) }
        case .gradient:
            return try gradient(value, path)
        case .lutTable:
            guard let text = value as? String, !text.isEmpty else {
                throw fail("\(path) must be a base64 string of little-endian f32 triples "
                    + "— or pass file, an absolute .cube path, and let the app build it")
            }
            return text
        case .text(let maxChars):
            guard let text = value as? String else { throw fail("\(path) must be a string") }
            // Unicode SCALARS, because that is what the core counts
            // (`adjust_lut::CubeLut::parse` tests `title.chars().count()`)
            // and what its .cube file parser truncates to. Swift's own
            // `count` is grapheme clusters, under which one family emoji is
            // 1 and seven scalars — so a title this gate passed could still
            // make the whole meta unparseable, and the caller would be told
            // `ok: true` and handed an inert raster layer.
            let length = text.unicodeScalars.count
            guard length <= maxChars else {
                throw fail("\(path) must be at most \(maxChars) characters "
                    + "(got \(length), counted the way the core counts them: Unicode "
                    + "scalars, so a combining mark or an emoji sequence is more than one)")
            }
            return text
        }
    }

    private static func number(
        _ value: Any, _ range: ClosedRange<Double>, _ path: String
    ) throws -> Double {
        guard let n = (value as? NSNumber)?.doubleValue, n.isFinite else {
            throw fail("\(path) must be a number")
        }
        guard range.contains(n) else {
            throw fail("\(path) must be between \(trim(range.lowerBound)) and "
                + "\(trim(range.upperBound)) (got \(trim(n)))")
        }
        return n
    }

    /// A bound printed the way it was written: 33 rather than 33.0.
    private static func trim(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9
            ? String(Int(value)) : String(format: "%g", value)
    }

    /// `#rrggbb` (or `#rrggbbaa`, whose alpha the core ignores), lowercased.
    private static func normalizedHex(_ text: String) -> String? {
        guard text.hasPrefix("#") else { return nil }
        let digits = text.dropFirst()
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return "#" + digits.prefix(6).lowercased()
    }

    /// The gradient object a Gradient Map carries — the same SHAPE a layer
    /// style's gradient has (one spelling in the core, one editor in the
    /// app), with its stop colours in the DOCUMENT's numbers. Ranges mirror
    /// core/src/style_json.rs's gradient parser; a map reads only `stops`
    /// and `reverse`, and the geometry keys are accepted and ignored.
    private static func gradient(_ value: Any, _ path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw fail("\(path) must be an object with stops")
        }
        let allowed = ["stops", "style", "angle", "scale", "reverse", "align_with_layer"]
        if let first = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw fail("Unknown \(path) parameter \"\(first)\" — \(path) takes "
                + allowed.joined(separator: ", ") + ".")
        }
        var out: [String: Any] = [:]
        if let raw = object["stops"] {
            guard let list = raw as? [Any], (2...32).contains(list.count) else {
                throw fail("\(path).stops must be an array of 2 to 32 stops")
            }
            var stops: [[String: Any]] = []
            for (i, entry) in list.enumerated() {
                let where_ = "\(path).stops[\(i)]"
                guard let stop = entry as? [String: Any] else {
                    throw fail("\(where_) must be an object "
                        + "{position, color, opacity}")
                }
                let keys = ["position", "color", "opacity"]
                if let bad = stop.keys.filter({ !keys.contains($0) }).sorted().first {
                    throw fail("Unknown \(where_) parameter \"\(bad)\" — a stop takes "
                        + keys.joined(separator: ", ") + ".")
                }
                var built: [String: Any] = [
                    "position": try number(stop["position"] ?? 0, 0...1, "\(where_).position"),
                    "opacity": try number(stop["opacity"] ?? 1, 0...1, "\(where_).opacity"),
                ]
                if let raw = stop["color"] {
                    guard let text = raw as? String, let hex = normalizedHex(text) else {
                        throw fail("\(where_).color must be a colour like \"#7f3f00\"")
                    }
                    built["color"] = hex
                } else {
                    built["color"] = "#000000"
                }
                stops.append(built)
            }
            out["stops"] = stops
        }
        if let raw = object["style"] {
            guard let text = raw as? String, GradientFill.styles.contains(text) else {
                throw fail("\(path).style must be one of "
                    + GradientFill.styles.joined(separator: ", "))
            }
            out["style"] = text
        }
        if let raw = object["angle"] { out["angle"] = try number(raw, -360...360, "\(path).angle") }
        if let raw = object["scale"] { out["scale"] = try number(raw, 0.1...1.5, "\(path).scale") }
        for key in ["reverse", "align_with_layer"] {
            guard let raw = object[key] else { continue }
            out[key] = try checked(raw, .boolean(false), "\(path).\(key)", .gradientMap)
        }
        return out
    }

    /// The cross-field rules a per-key table cannot express, in the same
    /// message style as the rest.
    private static func tail(_ op: AdjustmentLayerOp, _ params: inout [String: Any]) throws {
        switch op {
        case .hueSaturation:
            // The core reads a hue as [0, 360) — 360 and 0 are the same
            // angle, and accepting both would make two metas one picture.
            if let hue = params["colorize_hue"] as? Double, hue >= 360 {
                throw fail("colorize_hue must be between 0 and 360, 360 excluded (got 360)")
            }
            if var bands = params["bands"] as? [String: Any] {
                for name in hueBands {
                    guard let band = bands[name] as? [String: Any] else { continue }
                    if let center = band["center"] as? Double, center >= 360 {
                        throw fail("bands.\(name).center must be between 0 and 360, "
                            + "360 excluded (got 360)")
                    }
                    // An all-default band is dropped: it is the same picture
                    // and a shorter meta (the sheets do the same).
                    if band.isEmpty { bands.removeValue(forKey: name) }
                }
                params["bands"] = bands
            }
        case .colorLookup:
            guard let kind = params["kind"] as? String else {
                throw fail("color_lookup requires kind (\"1d\" or \"3d\") — or file, an "
                    + "absolute .cube path this app parses for you")
            }
            guard let size = params["size"] as? Int else {
                throw fail("color_lookup requires size, the number of nodes per axis")
            }
            let cap = kind == "3d" ? maxLUT3D : maxLUT1D
            guard Double(size) <= cap else {
                throw fail("size must be between 2 and \(Int(cap)) for a \(kind) LUT "
                    + "(got \(size)) — this build's storage cap; rz_lut_parse_cube "
                    + "resamples a larger .cube down to it and reports the file's own "
                    + "size as source_size")
            }
            guard let table = params["table"] as? String else {
                throw fail("color_lookup requires table, base64 of the LUT's f32 triples "
                    + "— or file, an absolute .cube path")
            }
            let nodes = kind == "3d" ? size * size * size : size
            let expected = nodes * 3 * 4
            guard let data = decodeBase64(table) else {
                throw fail("table is not valid base64")
            }
            guard data.count == expected else {
                throw fail("table must hold \(nodes) × 3 little-endian f32 "
                    + "(\(expected) bytes for a \(kind) LUT of size \(size)); "
                    + "got \(data.count)")
            }
            // The core refuses a non-finite entry too (adjust_lut.rs's
            // `CubeLut::parse`), but it refuses it the only way a meta
            // parser can — as "this meta is not an adjustment" — which is
            // the graceful-degradation path: the caller would be told the
            // layer was added and get an inert raster layer it could only
            // delete. So the gate is here, in the same wording the .cube
            // FILE parser uses, and the two construction paths of one
            // struct agree on which tables exist.
            if let bad = firstNonFiniteEntry(data) {
                throw fail("table entry \(bad) is not finite; every LUT value must be "
                    + "a finite little-endian f32")
            }
            let low = params["domain_min"] as? [Double] ?? [0, 0, 0]
            let high = params["domain_max"] as? [Double] ?? [1, 1, 1]
            // Compared AFTER narrowing to Float, because `adjust_lut::triple`
            // narrows both corners before `CubeLut::parse` re-checks
            // `hi > lo`: a pair that is strictly increasing in double and
            // collapses in float (1.0 and 1.0000000001) would otherwise pass
            // here and be refused there, and the refusal there is the "this
            // meta is not an adjustment" kind — an inert raster layer behind
            // an `ok: true`, the same outcome the `firstNonFiniteEntry` gate
            // above exists to prevent.
            guard zip(high, low).allSatisfy({ Float($0) > Float($1) }) else {
                throw fail("every domain_max component must be strictly above its "
                    + "domain_min once narrowed to the 32-bit floats the LUT is stored "
                    + "in (got \(low) and \(high))")
            }
            if let source = params["source_size"] as? Int, source < size {
                throw fail("source_size is the size the .cube FILE declared, so it is "
                    + "never below size (got \(source) with size \(size))")
            }
        case .gradientMap, .exposure, .vibrance, .colorBalance, .blackAndWhite,
            .photoFilter, .channelMixer, .selectiveColor, .shadowsHighlights,
            .whiteBalance:
            break
        case .bcs, .curves, .levels, .hueRotate, .posterize, .threshold,
            .invert, .grayscale, .sepia:
            break
        }
    }

    /// The index of the first LUT entry that is NaN or an infinity, or nil
    /// when every entry is finite. `data`'s length is already known to be a
    /// multiple of 4; the bytes are little-endian f32, the order the core
    /// decodes them in.
    private static func firstNonFiniteEntry(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        var i = 0
        while i + 4 <= bytes.count {
            let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            if !Float(bitPattern: bits).isFinite { return i / 4 }
            i += 4
        }
        return nil
    }

    /// Base64 the way the core reads it: ASCII whitespace skipped (a host
    /// may wrap the string), everything else strict, so this app and the
    /// core agree on which tables exist.
    ///
    /// `isWhitespace` alone is NOT that test, and using it was a bug:
    /// Swift's is the full Unicode White_Space property while
    /// `adjust_lut::base64_decode` skips only `is_ascii_whitespace`, so a
    /// table carrying a U+00A0 passed validation here and was then refused
    /// there — and `Adjustment::from_meta` refuses the WHOLE meta, leaving
    /// the caller an inert raster layer that no dialog will re-open. Every
    /// non-ASCII whitespace scalar therefore survives into
    /// `Data(base64Encoded:)`, which rejects it, and the caller gets the
    /// in-band "table is not valid base64" refusal instead.
    private static func decodeBase64(_ text: String) -> Data? {
        let packed = text.filter { !($0.isASCII && $0.isWhitespace) }
        return Data(base64Encoded: packed)
    }
}
