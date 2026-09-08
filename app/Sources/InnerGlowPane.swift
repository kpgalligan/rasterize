import AppKit

/// Layer Style > Inner Glow: a glow inside the shape, hugging the contour
/// (Source: Edge) or rising from the interior (Source: Center), with its own
/// blend mode (Screen by default), opacity and colour. Size is the glow's
/// extent in px; Choke is the fraction of it that stays hard (the core
/// dilates the outside — or erodes the shape, for Center — by size × choke
/// and blurs the rest). No light direction, so the context is unused.
final class InnerGlowPane: NSObject, LayerStylePane {
    let view: NSView
    private let rows: [PaneRow]

    init(binding: EffectBinding<InnerGlowEffect>, context: LayerStylePaneContext) {
        let blend = PaneRows.blendPopup(
            get: { binding.read().blend },
            set: { value in binding.update { $0.blend = value } })
        let opacity = PaneRows.percent(
            "Opacity:",
            get: { binding.read().opacity },
            set: { value in binding.update { $0.opacity = value } })
        let color = PaneRows.color(
            "Color:",
            get: { binding.read().color },
            set: { value in binding.update { $0.color = value } })
        let source = PaneRows.popup(
            "Source:", titles: ["Edge", "Center"], values: InnerGlowEffect.sources,
            get: { binding.read().source },
            set: { value in binding.update { $0.source = value } })
        let choke = PaneRows.percent(
            "Choke:",
            get: { binding.read().choke },
            set: { value in binding.update { $0.choke = value } })
        let size = PaneRows.pixels(
            "Size:", max: 250,
            get: { binding.read().size },
            set: { value in binding.update { $0.size = value } })
        rows = [blend, opacity, color, source, choke, size]
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
