import AppKit

/// Layer Style > Inner Shadow — the drop shadow's controls with Choke in
/// place of Spread (choke pulls the hard part of the shadow inward, the
/// mirror of spread pushing a drop shadow outward) and no knock-out (an
/// inner shadow is clipped to the shape by construction). Every control is
/// a `PaneRows` row bound straight to the effect; Angle with Use Global
/// Light on edits the DOCUMENT's light through the context, exactly as
/// `DropShadowPane` does, so the preview and every other effect reading
/// the global light follow the drag.
final class InnerShadowPane: NSObject, LayerStylePane {
    let view: NSView
    private let rows: [PaneRow]

    init(binding: EffectBinding<InnerShadowEffect>, context: LayerStylePaneContext) {
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
        // 250 px is the dialog's ceiling for both; the schema allows a
        // longer distance over MCP, which the readout still shows.
        let distance = PaneRows.pixels(
            "Distance:", max: 250,
            get: { binding.read().distance },
            set: { value in binding.update { $0.distance = value } })
        let choke = PaneRows.percent(
            "Choke:",
            get: { binding.read().choke },
            set: { value in binding.update { $0.choke = value } })
        let size = PaneRows.pixels(
            "Size:", max: 250,
            get: { binding.read().size },
            set: { value in binding.update { $0.size = value } })
        rows = [blend, color, opacity, angle, useGlobalLight, distance, choke, size]
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
