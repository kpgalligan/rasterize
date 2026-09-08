import AppKit

/// Layer Style > Drop Shadow — the pane the other effect panes are modelled
/// on: every control is a `PaneRows` row bound straight to the effect, and
/// Angle with Use Global Light on edits the DOCUMENT's light through the
/// context (so the preview, and every other effect reading the global
/// light, follows the drag).
final class DropShadowPane: NSObject, LayerStylePane {
    let view: NSView
    private let rows: [PaneRow]

    init(binding: EffectBinding<DropShadowEffect>, context: LayerStylePaneContext) {
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
        // With Use Global Light on, the slider shows and edits the document's
        // light (what the core actually reads); off, the effect's own angle.
        let angle = PaneRows.angle(
            "Angle:",
            get: {
                let fx = binding.read()
                return fx.useGlobalLight ? context.globalLight.read().angle : fx.angle
            },
            set: { value in
                if binding.read().useGlobalLight {
                    context.globalLight.update { $0.angle = value }
                } else {
                    binding.update { $0.angle = value }
                }
            })
        let useGlobalLight = PaneRows.checkbox(
            "Use Global Light",
            get: { binding.read().useGlobalLight },
            set: { on in
                // Turning it OFF keeps the angle being shown: the effect
                // adopts the global angle rather than jumping back to
                // whatever it held before (Photoshop does the same).
                let shown = context.globalLight.read().angle
                binding.update { fx in
                    fx.useGlobalLight = on
                    if !on { fx.angle = shown }
                }
                angle.reload()
            })
        let distance = PaneRows.pixels(
            "Distance:", max: 250,
            get: { binding.read().distance },
            set: { value in binding.update { $0.distance = value } })
        let spread = PaneRows.percent(
            "Spread:",
            get: { binding.read().spread },
            set: { value in binding.update { $0.spread = value } })
        let size = PaneRows.pixels(
            "Size:", max: 250,
            get: { binding.read().size },
            set: { value in binding.update { $0.size = value } })
        let knocksOut = PaneRows.checkbox(
            "Layer Knocks Out Drop Shadow",
            get: { binding.read().layerKnocksOut },
            set: { on in binding.update { $0.layerKnocksOut = on } })
        rows = [blend, color, opacity, angle, useGlobalLight, distance, spread, size, knocksOut]
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
