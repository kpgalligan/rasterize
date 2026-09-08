import AppKit

/// Layer Style > Stroke: Size, Position, Blend Mode, Opacity and the fill
/// — a colour swatch, or (Fill Type: Gradient) the gradient's end colours,
/// Reverse, Style, Align with Layer, Angle and Scale, in Photoshop's pane
/// order. Every control is a `PaneRows` row bound straight to the effect
/// (the sheet re-previews on each write). The rows the current fill type
/// does not use are hidden rather than disabled, so the pane reads as one
/// fill or the other.
final class StrokePane: NSObject, LayerStylePane {
    let view: NSView
    private let binding: EffectBinding<StrokeEffect>
    private let rows: [PaneRow]
    private let fillRows: FillRowsSwitch

    init(binding: EffectBinding<StrokeEffect>, context: LayerStylePaneContext) {
        self.binding = binding
        // The switch exists before the rows so the Fill Type popup's closure
        // can reach it; it learns the grid once the grid is built below.
        let fillRows = FillRowsSwitch()
        self.fillRows = fillRows

        let size = PaneRows.pixels(
            "Size:", max: 250,
            get: { binding.read().size },
            set: { value in binding.update { $0.size = value } })
        let position = PaneRows.popup(
            "Position:", titles: ["Outside", "Inside", "Center"],
            values: StrokeEffect.positions,
            get: { binding.read().position },
            set: { value in binding.update { $0.position = value } })
        let blend = PaneRows.blendPopup(
            get: { binding.read().blend },
            set: { value in binding.update { $0.blend = value } })
        let opacity = PaneRows.percent(
            "Opacity:",
            get: { binding.read().opacity },
            set: { value in binding.update { $0.opacity = value } })
        let fillType = PaneRows.popup(
            "Fill Type:", titles: ["Color", "Gradient"], values: StrokeEffect.fillTypes,
            get: { binding.read().fillType },
            set: { value in
                binding.update { $0.fillType = value }
                fillRows.apply(binding.read())
            })
        let color = PaneRows.color(
            "Color:",
            get: { binding.read().color },
            set: { value in binding.update { $0.color = value } })

        // Gradient fill. The sheet edits the two end stops; a gradient with
        // more stops (set over MCP or pasted) keeps its middle stops.
        let startColor = PaneRows.color(
            "Start Color:",
            get: { Self.stopColor(binding.read(), last: false) },
            set: { value in binding.update { Self.setStopColor(&$0, last: false, value) } })
        let endColor = PaneRows.color(
            "End Color:",
            get: { Self.stopColor(binding.read(), last: true) },
            set: { value in binding.update { Self.setStopColor(&$0, last: true, value) } })
        let stopsNote = PaneRows.note(
            "Only the first and last stops are edited here; the gradient's middle stops keep "
                + "their colours and positions.")
        let reverse = PaneRows.checkbox(
            "Reverse",
            get: { binding.read().gradient.reverse },
            set: { on in binding.update { $0.gradient.reverse = on } })
        let style = PaneRows.popup(
            "Style:", titles: ["Linear", "Radial", "Angle", "Reflected", "Diamond"],
            values: GradientFill.styles,
            get: { binding.read().gradient.style },
            set: { value in binding.update { $0.gradient.style = value } })
        let alignWithLayer = PaneRows.checkbox(
            "Align with Layer",
            get: { binding.read().gradient.alignWithLayer },
            set: { on in binding.update { $0.gradient.alignWithLayer = on } })
        let angle = PaneRows.angle(
            "Angle:",
            get: { binding.read().gradient.angle },
            set: { value in binding.update { $0.gradient.angle = value } })
        // The schema's 0.1…1.5 scale as Photoshop's 10…150 % readout.
        let scale = PaneRows.slider(
            "Scale:", min: 10, max: 150, integer: true,
            format: { String(format: "%.0f %%", $0) },
            get: { binding.read().gradient.scale * 100 },
            set: { value in binding.update { $0.gradient.scale = value / 100 } })

        rows = [
            size, position, blend, opacity, fillType, color, startColor, endColor, stopsNote,
            reverse, style, alignWithLayer, angle, scale,
        ]
        let grid = PaneRows.grid(rows)
        fillRows.grid = grid
        fillRows.colorRows = [5]
        fillRows.gradientRows = [6, 7, 9, 10, 11, 12, 13]
        fillRows.stopsNoteRow = 8
        fillRows.apply(binding.read())

        let stack = NSStackView(views: [grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        view = stack
        super.init()
    }

    func reload() {
        rows.forEach { $0.reload() }
        fillRows.apply(binding.read())
    }

    // MARK: - Stops

    /// The first (or last) stop's colour. The core requires two stops, so
    /// only a hand-built value can have fewer; those read as the defaults.
    private static func stopColor(_ fx: StrokeEffect, last: Bool) -> String {
        let stops = fx.gradient.stops.count >= 2 ? fx.gradient.stops : GradientFill().stops
        return (last ? stops.last : stops.first)?.color ?? "#000000"
    }

    /// Writes the first (or last) stop's colour, restoring the default stops
    /// first when the fill has fewer than two.
    private static func setStopColor(_ fx: inout StrokeEffect, last: Bool, _ hex: String) {
        if fx.gradient.stops.count < 2 {
            fx.gradient.stops = GradientFill().stops
        }
        let index = last ? fx.gradient.stops.count - 1 : 0
        fx.gradient.stops[index].color = hex
    }
}

/// Shows the grid rows of the current fill type and hides the other's; the
/// stops note only appears for a gradient with more than two stops.
private final class FillRowsSwitch {
    var grid: NSGridView?
    var colorRows: [Int] = []
    var gradientRows: [Int] = []
    var stopsNoteRow: Int?

    func apply(_ fx: StrokeEffect) {
        guard let grid = grid else { return }
        let gradient = fx.fillType == "gradient"
        for index in colorRows where index < grid.numberOfRows {
            grid.row(at: index).isHidden = gradient
        }
        for index in gradientRows where index < grid.numberOfRows {
            grid.row(at: index).isHidden = !gradient
        }
        if let index = stopsNoteRow, index < grid.numberOfRows {
            grid.row(at: index).isHidden = !gradient || fx.gradient.stops.count <= 2
        }
    }
}
