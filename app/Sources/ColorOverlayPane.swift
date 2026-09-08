import AppKit

/// Layer Style > Color Overlay: the layer's shape filled with one colour
/// above its pixels, at the overlay's OWN blend mode and opacity — never
/// the layer's ("Blend Interior Effects as Group" is off, Photoshop's
/// default), which is why a Multiply text layer with a white Normal overlay
/// shows white. Photoshop's three controls, each a `PaneRows` row bound
/// straight to the effect; the sheet re-previews on every change. Nothing
/// here reads the context: the overlay has no light and is never
/// canvas-aligned.
final class ColorOverlayPane: NSObject, LayerStylePane {
    let view: NSView
    private let rows: [PaneRow]

    init(binding: EffectBinding<ColorOverlayEffect>, context: LayerStylePaneContext) {
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
        let note = PaneRows.note(
            "Fills the layer's shape above its pixels. The overlay blends with its own mode; "
                + "the layer's blend mode and fill opacity apply to the pixels only.")
        rows = [blend, color, opacity, note]
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
