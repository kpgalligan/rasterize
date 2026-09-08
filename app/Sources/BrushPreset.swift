import Foundation

/// The paint tools' built-in tip presets: named combinations of the
/// options bar's tip fields (hardness, flow, spacing, angle, roundness,
/// airbrush). Selecting one applies its values to the active tool's
/// options; size and opacity are deliberately untouched — a preset shapes
/// the tip, not the hand. The popup's first row is "Custom", shown
/// whenever the current values match no preset; picking it changes
/// nothing.
struct BrushPreset {
    let name: String
    let hardness: Double
    let flow: Double
    let spacing: Double
    let angle: Double
    let roundness: Double
    let airbrush: Bool

    static let builtIns: [BrushPreset] = [
        BrushPreset(
            name: "Hard Round", hardness: 100, flow: 100, spacing: 25,
            angle: 0, roundness: 100, airbrush: false),
        BrushPreset(
            name: "Soft Round", hardness: 0, flow: 100, spacing: 25,
            angle: 0, roundness: 100, airbrush: false),
        BrushPreset(
            name: "Airbrush", hardness: 0, flow: 20, spacing: 15,
            angle: 0, roundness: 100, airbrush: true),
        BrushPreset(
            name: "Calligraphy", hardness: 95, flow: 100, spacing: 15,
            angle: -45, roundness: 30, airbrush: false),
        BrushPreset(
            name: "Flat Shader", hardness: 80, flow: 100, spacing: 20,
            angle: 90, roundness: 15, airbrush: false),
        BrushPreset(
            name: "Stippled", hardness: 100, flow: 100, spacing: 150,
            angle: 0, roundness: 100, airbrush: false),
    ]

    /// The popup's rows: "Custom" first, then every built-in.
    static let popupItems = ["Custom"] + builtIns.map { $0.name }

    /// The popup row the options currently show: a matching preset's row,
    /// or 0 (Custom). Values compare with a half-unit tolerance so a
    /// preset survives the store's Double round-trip.
    static func matchIndex(of options: PaintToolOptions) -> Int {
        for (i, preset) in builtIns.enumerated() where preset.matches(options) {
            return i + 1
        }
        return 0
    }

    private func matches(_ options: PaintToolOptions) -> Bool {
        abs(options.hardness - hardness) < 0.5
            && abs(options.flow - flow) < 0.5
            && abs(options.spacing - spacing) < 0.5
            && abs(options.angle - angle) < 0.5
            && abs(options.roundness - roundness) < 0.5
            && options.airbrush == airbrush
    }

    /// The options with this preset's tip applied (size, opacity and the
    /// rest untouched).
    func applied(to options: PaintToolOptions) -> PaintToolOptions {
        var out = options
        out.hardness = hardness
        out.flow = flow
        out.spacing = spacing
        out.angle = angle
        out.roundness = roundness
        out.airbrush = airbrush
        return out
    }
}
