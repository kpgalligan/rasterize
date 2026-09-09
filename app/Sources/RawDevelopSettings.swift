import Foundation

// The develop request a camera RAW open is parameterized by, in the two
// shapes it genuinely has. RawImage.swift decodes with them; the Develop
// window edits them; AgentServer+Raw.swift parses them off an MCP call.

/// The develop knobs this build exposes, as a SPARSE request: every field is
/// optional and nil means "keep the value this file's own decoder reports".
/// `RawDevelopSettings()` is therefore a complete, valid "as shot" request —
/// what an agent gets when it opens a RAW with no `raw` object, and what the
/// Develop window returns when the user moved nothing.
///
/// Sparse is the right shape for the two places a request is WRITTEN DOWN
/// (an MCP argument, and the settings a document remembers so Revert
/// re-develops identically), because the file's own defaults "vary per
/// image" (CIRAWFilter.h) and vary per decoder version: freezing today's
/// numbers into a stored request would silently change what "as shot" means
/// the next time the same file is opened. `RawDevelopValues` is the dense
/// twin the controls and the decode read, resolved against the file.
struct RawDevelopSettings: Equatable {
    /// Exposure in stops.
    var exposure: Double?

    /// White balance. Temperature and tint are ONE control: passing either
    /// one leaves the as-shot balance behind (the dialog's "Custom"), and
    /// `RawCapabilities.resolve` fills the other from the file. Passing
    /// neither is the as-shot balance, which the decode achieves by writing
    /// neither property.
    var temperature: Double?
    var tint: Double?

    /// The global tone curve (`boostAmount`): 0 is a linear response.
    var toneCurve: Double?
    /// Shadow lift (`boostShadowAmount`), inert while `toneCurve` is 0 —
    /// CIRAWFilter.h says so ("has no effect if the boostAmount is 0"), the
    /// catalog says so, and the dialog disables the row while Tone curve is
    /// there (`RawDevelopWindowController.applyEnablement`).
    var shadows: Double?
    /// Local contrast on edges (`contrastAmount`), not a global curve.
    var contrast: Double?
    var sharpness: Double?
    var detail: Double?
    var luminanceNoise: Double?
    var colorNoise: Double?
    var lensCorrection: Bool?
    /// macOS 26 and newer only — the pair of CIRAWFilter properties behind
    /// it is `NS_AVAILABLE(16_0, 19_0)`. Below that the dialog hides the row
    /// and the MCP handler refuses the key by name.
    var highlightRecovery: Bool?
}

/// The DENSE twin: every knob resolved against the file's own reported
/// value, which is what the dialog's controls display and what the decode
/// compares against to decide what to write. Produced only by
/// `RawCapabilities.resolve(_:)`.
struct RawDevelopValues: Equatable {
    var exposure: Double
    /// Whether temperature/tint are the user's or the file's. The dense form
    /// needs the flag because the sliders always show A number: "as shot"
    /// here means "these numbers came from the file", not "these are absent".
    var customWhiteBalance: Bool
    var temperature: Double
    var tint: Double
    var toneCurve: Double
    var shadows: Double
    var contrast: Double
    var sharpness: Double
    var detail: Double
    var luminanceNoise: Double
    var colorNoise: Double
    var lensCorrection: Bool
    var highlightRecovery: Bool

    /// This value set expressed as the sparse request that produces it from
    /// `defaults` — i.e. only what was actually moved. The Develop window
    /// hands this back, so a document remembers "exposure +1", never a full
    /// snapshot of one decoder version's idea of neutral.
    ///
    /// A Custom white balance whose numbers were never moved records
    /// nothing: writing a file's own temperature back is the balance it
    /// already had (the chromaticity round-trips to within 2e-5), so the two
    /// requests are the same decode and the shorter one is the honest
    /// record.
    func settings(against defaults: RawDevelopValues) -> RawDevelopSettings {
        var settings = RawDevelopSettings()
        if exposure != defaults.exposure { settings.exposure = exposure }
        if customWhiteBalance {
            if temperature != defaults.temperature { settings.temperature = temperature }
            if tint != defaults.tint { settings.tint = tint }
        }
        if toneCurve != defaults.toneCurve { settings.toneCurve = toneCurve }
        if shadows != defaults.shadows { settings.shadows = shadows }
        if contrast != defaults.contrast { settings.contrast = contrast }
        if sharpness != defaults.sharpness { settings.sharpness = sharpness }
        if detail != defaults.detail { settings.detail = detail }
        if luminanceNoise != defaults.luminanceNoise { settings.luminanceNoise = luminanceNoise }
        if colorNoise != defaults.colorNoise { settings.colorNoise = colorNoise }
        if lensCorrection != defaults.lensCorrection { settings.lensCorrection = lensCorrection }
        if highlightRecovery != defaults.highlightRecovery {
            settings.highlightRecovery = highlightRecovery
        }
        return settings
    }
}

/// The ranges every knob is clamped into (the dialog) or refused against
/// (the MCP handler).
///
/// Each is the FRAMEWORK's own documented range wherever it states one —
/// `CIRAWFilter.h` gives 0…1 for the tone curve, the noise pair, sharpness
/// and local contrast, 0…3 for detail, 0…2 for the shadow boost and
/// "(2000K..50000K, -150..150)" for the white balance — so a value the
/// framework would honour is never refused. Exposure is the one knob the
/// header leaves unstated; ±4 stops is this build's choice, wide enough for
/// any real recovery and narrow enough to make a slider usable, and it is
/// documented as ours rather than dressed up as the framework's.
enum RawDevelopRange {
    static let exposure = -4.0...4.0
    static let temperature = 2000.0...50000.0
    static let tint = -150.0...150.0
    static let toneCurve = 0.0...1.0
    static let shadows = 0.0...2.0
    static let contrast = 0.0...1.0
    static let sharpness = 0.0...1.0
    static let detail = 0.0...3.0
    static let luminanceNoise = 0.0...1.0
    static let colorNoise = 0.0...1.0
}

extension ClosedRange where Bound == Double {
    /// `value` brought inside this range, with a non-finite value answered
    /// by `fallback` — the framework validates nothing (`boostAmount = 5`
    /// and `scaleFactor = 0` are both stored verbatim and produce garbage),
    /// so every write this side makes is clamped first.
    func clamping(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

/// How the NEXT document open should treat a camera RAW.
///
/// `.ask` puts up the Develop window before any pixels land, and a cancel
/// opens nothing. `.headless` develops with the settings given and shows no
/// UI at all — the mode every programmatic open uses, because a modal window
/// on the agent trampoline's main-thread hop would hang the MCP connection.
///
/// It is a two-case enum and not an optional because the two questions are
/// independent: "no settings" is a perfectly ordinary headless request (an
/// agent opening a RAW as shot), and it must not read as "ask the user".
enum RawImportMode {
    case ask
    case headless(RawDevelopSettings)
}

/// The one-slot channel from an open's CALLER to `ImageDocument.read`, which
/// AppKit gives no way to pass an argument through.
///
/// Main thread only, and always set and cleared with a `defer` around the
/// open it belongs to: `NSDocumentController` opens documents synchronously
/// on the main thread, so the value cannot be observed by anything but the
/// open it was set for. Three writers — the agent's `open_document`, Batch,
/// and `revert(toContentsOf:ofType:)` — and one reader, the RAW branch of
/// `ImageDocument.openDocument`.
enum RawImportRequest {
    static var mode: RawImportMode = .ask
}
