import AppKit

/// Layer Style > Bevel & Emboss — the relief pane: structure (style,
/// depth, direction, size, soften), the light (angle and altitude, both
/// following the document's global light while Use Global Light is on, the
/// DropShadowPane pattern), and the highlight and shadow halves, each with
/// its own blend mode, colour and opacity. Every control writes through the
/// binding; the sheet previews through the projection.
final class BevelEmbossPane: NSObject, LayerStylePane {
    let view: NSView
    private let rows: [PaneRow]

    init(binding: EffectBinding<BevelEmbossEffect>, context: LayerStylePaneContext) {
        // -- Structure --
        let style = PaneRows.popup(
            "Style:",
            titles: ["Outer Bevel", "Inner Bevel", "Emboss", "Pillow Emboss"],
            values: BevelEmbossEffect.styles,
            get: { binding.read().style },
            set: { value in binding.update { $0.style = value } })
        // Photoshop's Depth is 1…1000 %; the model holds 1.0 = 100 %.
        let depth = PaneRows.slider(
            "Depth:", min: 1, max: 1000, integer: true,
            format: { String(format: "%.0f %%", $0) },
            get: { binding.read().depth * 100 },
            set: { value in binding.update { $0.depth = value / 100 } })
        let direction = PaneRows.popup(
            "Direction:",
            titles: ["Up", "Down"],
            values: BevelEmbossEffect.directions,
            get: { binding.read().direction },
            set: { value in binding.update { $0.direction = value } })
        let size = PaneRows.pixels(
            "Size:", max: 250,
            get: { binding.read().size },
            set: { value in binding.update { $0.size = value } })
        let soften = PaneRows.pixels(
            "Soften:", max: 16,
            get: { binding.read().soften },
            set: { value in binding.update { $0.soften = value } })

        // -- Shading -- With Use Global Light on, Angle and Altitude show
        // and edit the document's light (what the core actually reads);
        // off, the effect's own.
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
        let altitude = PaneRows.slider(
            "Altitude:", min: 0, max: 90, integer: true,
            format: { String(format: "%.0f°", $0) },
            get: {
                let fx = binding.read()
                return fx.useGlobalLight ? context.globalLight.read().altitude : fx.altitude
            },
            set: { value in
                if binding.read().useGlobalLight {
                    context.globalLight.update { $0.altitude = value }
                } else {
                    binding.update { $0.altitude = value }
                }
            })
        let useGlobalLight = PaneRows.checkbox(
            "Use Global Light",
            get: { binding.read().useGlobalLight },
            set: { on in
                // Turning it OFF keeps the light being shown: the effect
                // adopts the global angle and altitude rather than jumping
                // back to whatever it held before (Photoshop does the same).
                let shown = context.globalLight.read()
                binding.update { fx in
                    fx.useGlobalLight = on
                    if !on {
                        fx.angle = shown.angle
                        fx.altitude = shown.altitude
                    }
                }
                angle.reload()
                altitude.reload()
            })

        // -- Highlight and shadow --
        let highlightBlend = PaneRows.blendPopup(
            "Highlight Mode:",
            get: { binding.read().highlightBlend },
            set: { value in binding.update { $0.highlightBlend = value } })
        let highlightColor = PaneRows.color(
            "Highlight Color:",
            get: { binding.read().highlightColor },
            set: { value in binding.update { $0.highlightColor = value } })
        let highlightOpacity = PaneRows.percent(
            "Highlight Opacity:",
            get: { binding.read().highlightOpacity },
            set: { value in binding.update { $0.highlightOpacity = value } })
        let shadowBlend = PaneRows.blendPopup(
            "Shadow Mode:",
            get: { binding.read().shadowBlend },
            set: { value in binding.update { $0.shadowBlend = value } })
        let shadowColor = PaneRows.color(
            "Shadow Color:",
            get: { binding.read().shadowColor },
            set: { value in binding.update { $0.shadowColor = value } })
        let shadowOpacity = PaneRows.percent(
            "Shadow Opacity:",
            get: { binding.read().shadowOpacity },
            set: { value in binding.update { $0.shadowOpacity = value } })

        rows = [
            style, depth, direction, size, soften,
            angle, altitude, useGlobalLight,
            highlightBlend, highlightColor, highlightOpacity,
            shadowBlend, shadowColor, shadowOpacity,
        ]
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
