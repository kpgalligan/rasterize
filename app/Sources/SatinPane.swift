import AppKit

/// Layer Style > Satin: the sheen of two copies of the blurred shape pushed
/// apart along Angle by Distance and combined where exactly one of them
/// covers a pixel (Invert shows the complement), clipped to the shape and
/// composited above the pixels with its own blend mode. Every control is a
/// `PaneRows` row bound straight to the effect. Angle is the effect's own —
/// Photoshop's Satin pane has no Use Global Light — so this pane never
/// touches the context's light; the core (`style_fx_satin.rs`) owns the
/// rendering and the sheet owns preview and commit.
final class SatinPane: NSObject, LayerStylePane {
    let view: NSView
    private let rows: [PaneRow]

    init(binding: EffectBinding<SatinEffect>, context: LayerStylePaneContext) {
        let blend = PaneRows.blendPopup(
            get: { binding.read().blend },
            set: { value in binding.update { $0.blend = value } })
        let color = PaneRows.color(
            "Color:",
            get: { binding.read().color },
            set: { value in binding.update { $0.color = value } })
        let opacity = PaneRows.percent(
            "Opacity:",
            get: { binding.read().opacity },
            set: { value in binding.update { $0.opacity = value } })
        let angle = PaneRows.angle(
            "Angle:",
            get: { binding.read().angle },
            set: { value in binding.update { $0.angle = value } })
        // 250 px is Photoshop's ceiling for both sliders; the schema allows
        // more over MCP and the readout shows whatever the model holds.
        let distance = PaneRows.pixels(
            "Distance:", max: 250,
            get: { binding.read().distance },
            set: { value in binding.update { $0.distance = value } })
        let size = PaneRows.pixels(
            "Size:", max: 250,
            get: { binding.read().size },
            set: { value in binding.update { $0.size = value } })
        let invert = PaneRows.checkbox(
            "Invert",
            get: { binding.read().invert },
            set: { on in binding.update { $0.invert = on } })
        rows = [blend, color, opacity, angle, distance, size, invert]
        let stack = NSStackView(views: [PaneRows.grid(rows)])
        stack.orientation = .vertical
        stack.alignment = .leading
        view = stack
        super.init()
    }

    func reload() {
        rows.forEach { $0.reload() }
    }
}
