import AppKit

/// The typed Swift view of a layer style — Photoshop's effect stack plus the
/// blending options beyond opacity and mode — mirroring the core's JSON
/// contract key for key (core/src/style.rs is the schema; this file only
/// reads the core's canonical JSON back into values the dialog can bind to
/// and writes them out again). The core canonicalizes, clamps, quantizes and
/// enforces the identity rule; nothing here re-derives any of that.
///
/// The value types are `Codable` with the snake-case key strategies, so
/// each Swift property name IS its JSON key (`useGlobalLight` ↔
/// `use_global_light`). The effect structs decode with Swift's synthesized
/// initializers, which need every key present — always true of the core's
/// canonical output, the only JSON `decode` ever sees.

/// The document's shared light direction, read by every effect with
/// `use_global_light` on. Degrees, Photoshop convention: 0 = light from the
/// right, 90 = from the top; altitude 0…90.
struct GlobalLight: Equatable {
    var angle: Double = 120
    var altitude: Double = 30
}

/// The nine effects. The raw value is the JSON `type`; the declaration
/// order is the Layer Style sheet's checklist order (Photoshop's dialog
/// order, top to bottom) and the Layer > Layer Style submenu's — NOT the
/// render order, which the core owns.
enum LayerStyleEffectKind: String, CaseIterable {
    case bevelEmboss = "bevel_emboss"
    case stroke
    case innerShadow = "inner_shadow"
    case innerGlow = "inner_glow"
    case satin
    case colorOverlay = "color_overlay"
    case gradientOverlay = "gradient_overlay"
    case outerGlow = "outer_glow"
    case dropShadow = "drop_shadow"

    var title: String {
        switch self {
        case .bevelEmboss: return "Bevel & Emboss"
        case .stroke: return "Stroke"
        case .innerShadow: return "Inner Shadow"
        case .innerGlow: return "Inner Glow"
        case .satin: return "Satin"
        case .colorOverlay: return "Color Overlay"
        case .gradientOverlay: return "Gradient Overlay"
        case .outerGlow: return "Outer Glow"
        case .dropShadow: return "Drop Shadow"
        }
    }
}

/// The style JSON's blend names ↔ `RzBlendMode`: the 27 layer blend modes
/// as snake_case Photoshop names, ONE table in `RzBlendMode.allBlendModes`
/// order. `linear_dodge` is `RZ_BLEND_ADDITION` (Photoshop's "Linear Dodge
/// (Add)"); every other name is the display name lowercased with
/// underscores.
enum LayerStyleBlend {
    static let names: [(RzBlendMode, String)] = [
        (RZ_BLEND_NORMAL, "normal"),
        (RZ_BLEND_DISSOLVE, "dissolve"),
        (RZ_BLEND_DARKEN, "darken"),
        (RZ_BLEND_MULTIPLY, "multiply"),
        (RZ_BLEND_COLOR_BURN, "color_burn"),
        (RZ_BLEND_LINEAR_BURN, "linear_burn"),
        (RZ_BLEND_DARKER_COLOR, "darker_color"),
        (RZ_BLEND_LIGHTEN, "lighten"),
        (RZ_BLEND_SCREEN, "screen"),
        (RZ_BLEND_COLOR_DODGE, "color_dodge"),
        (RZ_BLEND_ADDITION, "linear_dodge"),
        (RZ_BLEND_LIGHTER_COLOR, "lighter_color"),
        (RZ_BLEND_OVERLAY, "overlay"),
        (RZ_BLEND_SOFT_LIGHT, "soft_light"),
        (RZ_BLEND_HARD_LIGHT, "hard_light"),
        (RZ_BLEND_VIVID_LIGHT, "vivid_light"),
        (RZ_BLEND_LINEAR_LIGHT, "linear_light"),
        (RZ_BLEND_PIN_LIGHT, "pin_light"),
        (RZ_BLEND_HARD_MIX, "hard_mix"),
        (RZ_BLEND_DIFFERENCE, "difference"),
        (RZ_BLEND_EXCLUSION, "exclusion"),
        (RZ_BLEND_SUBTRACT, "subtract"),
        (RZ_BLEND_DIVIDE, "divide"),
        (RZ_BLEND_HUE, "hue"),
        (RZ_BLEND_SATURATION, "saturation"),
        (RZ_BLEND_COLOR, "color"),
        (RZ_BLEND_LUMINOSITY, "luminosity"),
    ]

    /// The JSON names alone, in menu order — the catalog's enum.
    static let allNames: [String] = names.map { $0.1 }

    static func name(for mode: RzBlendMode) -> String {
        names.first { $0.0 == mode }?.1 ?? "normal"
    }

    static func mode(named name: String) -> RzBlendMode? {
        names.first { $0.1 == name }?.0
    }
}

/// Colours cross the style JSON as "#rrggbb" — six digits, lowercase, no
/// alpha (every effect has its own opacity). NOT `TextLayer.hex`, which
/// writes eight.
enum LayerStyleColor {
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? .black
        let byte: (CGFloat) -> Int = { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02x%02x%02x",
            byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// Parses "#rrggbb" (and, leniently, "#rrggbbaa" — the core accepts it
    /// and ignores the alpha); nil on anything else.
    static func color(fromHex string: String) -> NSColor? {
        TextLayer.color(fromHex: string)
    }
}

// MARK: - Shared sub-objects

struct GradientStop: Codable, Equatable {
    var position: Double
    var color: String
    var opacity: Double
}

/// Shared by `stroke` (gradient fill) and `gradient_overlay`.
struct GradientFill: Codable, Equatable {
    var stops: [GradientStop] = [
        GradientStop(position: 0, color: "#000000", opacity: 1),
        GradientStop(position: 1, color: "#ffffff", opacity: 1),
    ]
    var style = "linear"
    var angle = 90.0
    var scale = 1.0
    var reverse = false
    var alignWithLayer = true

    static let styles = ["linear", "radial", "angle", "reflected", "diamond"]
}

/// Blending Options > Blend If: two split-slider ramps, `[lo0, lo1, hi0,
/// hi1]` over 0…255 with `lo0 <= lo1 <= hi0 <= hi1`, on this layer's and
/// the underlying composite's channel.
struct BlendIf: Codable, Equatable {
    static let fullRamp = [0, 0, 255, 255]
    static let channels = ["gray", "red", "green", "blue"]

    var channel = "gray"
    var thisLayer = BlendIf.fullRamp
    var underlying = BlendIf.fullRamp

    /// Full weight everywhere — the core's `BlendIf::is_identity`, which
    /// ignores the channel (a full ramp weights every channel the same).
    var isIdentity: Bool {
        thisLayer == BlendIf.fullRamp && underlying == BlendIf.fullRamp
    }
}

// MARK: - Effects (defaults are the core's; see core/src/style.rs)

struct DropShadowEffect: Codable, Equatable {
    var type = LayerStyleEffectKind.dropShadow.rawValue
    var enabled = true
    var blend = "multiply"
    var color = "#000000"
    var opacity = 0.75
    var angle = 120.0
    var useGlobalLight = true
    var distance = 5.0
    var spread = 0.0
    var size = 5.0
    /// Photoshop's "Layer Knocks Out Drop Shadow": the shadow is not drawn
    /// under the layer's own shape (visible only at fill opacity below 1).
    var layerKnocksOut = true
}

struct InnerShadowEffect: Codable, Equatable {
    var type = LayerStyleEffectKind.innerShadow.rawValue
    var enabled = true
    var blend = "multiply"
    var color = "#000000"
    var opacity = 0.75
    var angle = 120.0
    var useGlobalLight = true
    var distance = 5.0
    var choke = 0.0
    var size = 5.0
}

struct OuterGlowEffect: Codable, Equatable {
    var type = LayerStyleEffectKind.outerGlow.rawValue
    var enabled = true
    var blend = "screen"
    var color = "#ffffbe"
    var opacity = 0.75
    var spread = 0.0
    var size = 5.0
}

struct InnerGlowEffect: Codable, Equatable {
    static let sources = ["edge", "center"]

    var type = LayerStyleEffectKind.innerGlow.rawValue
    var enabled = true
    var blend = "screen"
    var color = "#ffffbe"
    var opacity = 0.75
    var choke = 0.0
    var size = 5.0
    var source = "edge"
}

struct StrokeEffect: Codable, Equatable {
    static let positions = ["outside", "inside", "center"]
    static let fillTypes = ["color", "gradient"]

    var type = LayerStyleEffectKind.stroke.rawValue
    var enabled = true
    var blend = "normal"
    var opacity = 1.0
    var size = 3.0
    var position = "outside"
    var fillType = "color"
    var color = "#000000"
    var gradient = GradientFill()
}

struct ColorOverlayEffect: Codable, Equatable {
    var type = LayerStyleEffectKind.colorOverlay.rawValue
    var enabled = true
    var blend = "normal"
    var color = "#ff0000"
    var opacity = 1.0
}

struct GradientOverlayEffect: Codable, Equatable {
    var type = LayerStyleEffectKind.gradientOverlay.rawValue
    var enabled = true
    var blend = "normal"
    var opacity = 1.0
    var gradient = GradientFill()
}

struct BevelEmbossEffect: Codable, Equatable {
    static let styles = ["outer_bevel", "inner_bevel", "emboss", "pillow_emboss"]
    static let directions = ["up", "down"]

    var type = LayerStyleEffectKind.bevelEmboss.rawValue
    var enabled = true
    var style = "inner_bevel"
    /// 1.0 is Photoshop's 100 %; the core clamps to 0.01…10.
    var depth = 1.0
    var direction = "up"
    var size = 5.0
    var soften = 0.0
    var angle = 120.0
    var useGlobalLight = true
    var altitude = 30.0
    var highlightBlend = "screen"
    var highlightColor = "#ffffff"
    var highlightOpacity = 0.75
    var shadowBlend = "multiply"
    var shadowColor = "#000000"
    var shadowOpacity = 0.75
}

struct SatinEffect: Codable, Equatable {
    var type = LayerStyleEffectKind.satin.rawValue
    var enabled = true
    var blend = "multiply"
    var color = "#000000"
    var opacity = 0.5
    var angle = 19.0
    var distance = 11.0
    var size = 14.0
    var invert = true
}

// MARK: - The style

/// One layer's style. `Codable` by hand at the top level because the
/// effects live in the JSON as an unkeyed `"effects"` array of typed
/// objects — read by peeking each element's `type`, written in checklist
/// order (the core re-sorts into render order); the structs themselves
/// use the synthesized coders.
struct LayerStyle: Codable, Equatable {
    var version = 1
    /// Opacity of the PIXELS only, never of the effects.
    var fillOpacity = 1.0
    var blendIf: BlendIf? = nil
    var dropShadow: DropShadowEffect? = nil
    var innerShadow: InnerShadowEffect? = nil
    var outerGlow: OuterGlowEffect? = nil
    var innerGlow: InnerGlowEffect? = nil
    var stroke: StrokeEffect? = nil
    var colorOverlay: ColorOverlayEffect? = nil
    var gradientOverlay: GradientOverlayEffect? = nil
    var bevelEmboss: BevelEmbossEffect? = nil
    var satin: SatinEffect? = nil

    init() {}

    // MARK: Effects by kind

    /// Present — enabled or not (a disabled effect keeps its settings).
    func hasEffect(_ kind: LayerStyleEffectKind) -> Bool {
        enabledFlag(kind) != nil
    }

    func effectEnabled(_ kind: LayerStyleEffectKind) -> Bool {
        enabledFlag(kind) ?? false
    }

    /// Turns an effect on or off; enabling one that was never set creates
    /// it with the core's defaults, and disabling keeps it (its settings
    /// survive a round trip through the checklist, as in Photoshop).
    mutating func setEffectEnabled(_ kind: LayerStyleEffectKind, _ on: Bool) {
        switch kind {
        case .dropShadow:
            var fx = dropShadow ?? DropShadowEffect()
            fx.enabled = on
            dropShadow = fx
        case .innerShadow:
            var fx = innerShadow ?? InnerShadowEffect()
            fx.enabled = on
            innerShadow = fx
        case .outerGlow:
            var fx = outerGlow ?? OuterGlowEffect()
            fx.enabled = on
            outerGlow = fx
        case .innerGlow:
            var fx = innerGlow ?? InnerGlowEffect()
            fx.enabled = on
            innerGlow = fx
        case .stroke:
            var fx = stroke ?? StrokeEffect()
            fx.enabled = on
            stroke = fx
        case .colorOverlay:
            var fx = colorOverlay ?? ColorOverlayEffect()
            fx.enabled = on
            colorOverlay = fx
        case .gradientOverlay:
            var fx = gradientOverlay ?? GradientOverlayEffect()
            fx.enabled = on
            gradientOverlay = fx
        case .bevelEmboss:
            var fx = bevelEmboss ?? BevelEmbossEffect()
            fx.enabled = on
            bevelEmboss = fx
        case .satin:
            var fx = satin ?? SatinEffect()
            fx.enabled = on
            satin = fx
        }
    }

    /// The enabled effects in checklist order.
    var enabledKinds: [LayerStyleEffectKind] {
        LayerStyleEffectKind.allCases.filter { effectEnabled($0) }
    }

    /// Renders nothing: fill opacity 1, no (or a full-weight) Blend If, no
    /// enabled effect — the core's rule, mirrored ONLY for the sheet's
    /// Apply/Reset comparisons and the paste guard; the core enforces it
    /// (an identity style is never stored: setting one clears).
    var isIdentity: Bool {
        fillOpacity >= 1 && (blendIf?.isIdentity ?? true) && enabledKinds.isEmpty
    }

    /// nil when the effect is absent, else its enabled flag.
    private func enabledFlag(_ kind: LayerStyleEffectKind) -> Bool? {
        switch kind {
        case .dropShadow: return dropShadow?.enabled
        case .innerShadow: return innerShadow?.enabled
        case .outerGlow: return outerGlow?.enabled
        case .innerGlow: return innerGlow?.enabled
        case .stroke: return stroke?.enabled
        case .colorOverlay: return colorOverlay?.enabled
        case .gradientOverlay: return gradientOverlay?.enabled
        case .bevelEmboss: return bevelEmboss?.enabled
        case .satin: return satin?.enabled
        }
    }

    // MARK: JSON

    private enum CodingKeys: String, CodingKey {
        case version, fillOpacity, blendIf, effects
    }

    /// Reads one element's `type` without consuming it from the real
    /// container (decoding from a COPY of an unkeyed container advances only
    /// the copy).
    private struct TypeProbe: Decodable {
        let type: String
    }

    /// Consumes one element of any object shape — how an unknown effect
    /// type (a newer core's) is skipped rather than refused.
    private struct SkippedEffect: Decodable {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        fillOpacity = try c.decodeIfPresent(Double.self, forKey: .fillOpacity) ?? 1
        blendIf = try c.decodeIfPresent(BlendIf.self, forKey: .blendIf)
        guard c.contains(.effects) else { return }
        var effects = try c.nestedUnkeyedContainer(forKey: .effects)
        while !effects.isAtEnd {
            let probe = effects
            let type = try LayerStyle.peekType(probe)
            switch LayerStyleEffectKind(rawValue: type) {
            case .dropShadow: dropShadow = try effects.decode(DropShadowEffect.self)
            case .innerShadow: innerShadow = try effects.decode(InnerShadowEffect.self)
            case .outerGlow: outerGlow = try effects.decode(OuterGlowEffect.self)
            case .innerGlow: innerGlow = try effects.decode(InnerGlowEffect.self)
            case .stroke: stroke = try effects.decode(StrokeEffect.self)
            case .colorOverlay: colorOverlay = try effects.decode(ColorOverlayEffect.self)
            case .gradientOverlay:
                gradientOverlay = try effects.decode(GradientOverlayEffect.self)
            case .bevelEmboss: bevelEmboss = try effects.decode(BevelEmbossEffect.self)
            case .satin: satin = try effects.decode(SatinEffect.self)
            case nil: _ = try effects.decode(SkippedEffect.self)
            }
        }
    }

    private static func peekType(_ container: UnkeyedDecodingContainer) throws -> String {
        var copy = container
        return try copy.decode(TypeProbe.self).type
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(fillOpacity, forKey: .fillOpacity)
        // An explicit null, the canonical spelling of "no Blend If".
        try c.encode(blendIf, forKey: .blendIf)
        var effects = c.nestedUnkeyedContainer(forKey: .effects)
        for kind in LayerStyleEffectKind.allCases {
            switch kind {
            case .dropShadow: if let fx = dropShadow { try effects.encode(fx) }
            case .innerShadow: if let fx = innerShadow { try effects.encode(fx) }
            case .outerGlow: if let fx = outerGlow { try effects.encode(fx) }
            case .innerGlow: if let fx = innerGlow { try effects.encode(fx) }
            case .stroke: if let fx = stroke { try effects.encode(fx) }
            case .colorOverlay: if let fx = colorOverlay { try effects.encode(fx) }
            case .gradientOverlay: if let fx = gradientOverlay { try effects.encode(fx) }
            case .bevelEmboss: if let fx = bevelEmboss { try effects.encode(fx) }
            case .satin: if let fx = satin { try effects.encode(fx) }
            }
        }
    }

    /// The style as JSON the core accepts (snake_case keys, sorted for a
    /// byte-stable no-op compare); nil only for a non-finite number, which
    /// no control produces.
    func json() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The core's canonical JSON back into a value; nil on anything
    /// malformed (never throws to callers — the dialog then opens on a
    /// fresh style).
    static func decode(_ json: String) -> LayerStyle? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(LayerStyle.self, from: data)
    }
}

// MARK: - Reading and writing the style on a document layer

extension RasterDocument {
    /// Layer `idx`'s style as a typed value, or nil when it has none.
    func layerStylePayload(_ idx: Int) -> LayerStyle? {
        layerStyle(idx).flatMap(LayerStyle.decode)
    }

    /// Attaches `style` to layer `idx`, or CLEARS it when nil. An identity
    /// style is passed as nil — the core would clear it anyway (its one
    /// rule), and passing nil keeps the "unchanged" refusal exact for an
    /// unstyled layer. nil for an unchanged value or a bad index; throws
    /// with the core's message for a style the core refuses.
    func withLayerStylePayload(_ idx: Int, _ style: LayerStyle?) throws -> RasterDocument? {
        guard let style = style, !style.isIdentity else { return try withLayerStyle(idx, nil) }
        guard let json = style.json() else { return nil }
        return try withLayerStyle(idx, json)
    }

    var globalLight: GlobalLight {
        GlobalLight(angle: globalLightAngle, altitude: globalLightAltitude)
    }

    func withGlobalLight(_ light: GlobalLight) -> RasterDocument? {
        withGlobalLight(angle: light.angle, altitude: light.altitude)
    }
}
