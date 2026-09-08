import AppKit

/// View ▸ New Guide…: an orientation and a position, typed in the ruler's
/// current unit.
///
/// The position is read and written FROM THE RULER ORIGIN — the one other
/// place the origin means anything at all (it moves labels, and this field,
/// and nothing else): the number typed here is one the user read off a
/// ruler, so it must agree with the ruler. `onCommit` receives the ABSOLUTE
/// canvas coordinate, which is what the core stores and what MCP reports.
///
/// It captures the unit, the ppi, the canvas size AND the ruler origin at
/// init and hands the same four to its commit, per `app/CLAUDE.md`'s sheet
/// rule: a document-modal sheet does not stop the main run loop, so an
/// agent's `set_resolution` or `set_ruler_origin` can land behind it, and a
/// commit computed from the NEW values would place a guide the user never
/// saw described.
///
/// A typed position is deliberately NOT rounded to whole pixels; only a
/// guide placed by a DRAG is (see `GuideDragSession`).
final class NewGuideSheetController: NSViewController {
    private let unit: CanvasUnit
    private let ppi: (x: Double, y: Double)
    private let canvas: CGSize
    private let rulerOrigin: CGPoint
    private let onCommit: (GuideOrientation, Double) -> Void

    private let horizontalRadio = NSButton(
        radioButtonWithTitle: "Horizontal", target: nil, action: nil)
    private let verticalRadio = NSButton(
        radioButtonWithTitle: "Vertical", target: nil, action: nil)
    private let positionField = NSTextField(string: "")

    /// The orientation whose centre the field is currently showing. AppKit
    /// switches a radio pair's states BEFORE the action fires, so the
    /// control itself cannot say what the choice was a moment ago.
    private var seededOrientation: GuideOrientation = .horizontal
    /// Exactly what the sheet last WROTE into the field, so a flip can tell
    /// its own seed from a number the user typed. Compared as text rather
    /// than as a Double: the formatter renders in the user's locale and to
    /// its own decimal count, so only the string it produced round-trips.
    private var seededText = ""

    init(
        unit: CanvasUnit, ppi: (x: Double, y: Double), canvas: CGSize,
        rulerOrigin: CGPoint, onCommit: @escaping (GuideOrientation, Double) -> Void
    ) {
        self.unit = unit
        self.ppi = ppi
        self.canvas = canvas
        self.rulerOrigin = rulerOrigin
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NewGuideSheetController does not support NSCoder")
    }

    override func loadView() {
        for radio in [horizontalRadio, verticalRadio] {
            radio.target = self
            radio.action = #selector(orientationChanged(_:))
            radio.font = DS.sans(13)
        }
        // Horizontal first, which is Photoshop's own default in this dialog.
        horizontalRadio.state = .on
        verticalRadio.state = .off
        let orientationRow = NSStackView(views: [horizontalRadio, verticalRadio])
        orientationRow.orientation = .horizontal
        orientationRow.spacing = 14

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = true
        formatter.minimumFractionDigits = 0
        // Four decimals is the core's own quantization (`q4`) and the ruler
        // labels' ceiling (`RulerTicks.maxDecimals`), so a number typed here
        // can always be written back exactly as it is stored.
        formatter.maximumFractionDigits = RulerTicks.maxDecimals
        positionField.formatter = formatter
        positionField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        DSField.style(positionField)
        seed(seededOrientation)

        let unitLabel = NSTextField(labelWithString: unit.abbreviation)
        unitLabel.font = DS.mono(13)
        unitLabel.textColor = DS.textMuted
        let positionRow = NSStackView(views: [positionField, unitLabel])
        positionRow.orientation = .horizontal
        positionRow.spacing = 8

        let grid = NSGridView(views: [
            [fieldLabel("Orientation:"), orientationRow],
            [fieldLabel("Position:"), positionRow],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "New Guide",
            hint: "The position is measured from the ruler origin, exactly as the rulers "
                + "label it, and starts at the canvas centre. Horizontal guides take "
                + "\(rangeText(.horizontal)); vertical guides \(rangeText(.vertical)).",
            content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("one undo step")]))
    }

    // MARK: - The unit conversion, on the guide's own axis

    /// Canvas pixels per one unit on the axis this orientation is measured
    /// along: a HORIZONTAL guide has a constant y, so it is measured down
    /// the height, with `ppi.y`.
    private func pixelsPerUnit(_ orientation: GuideOrientation) -> Double {
        unit.pixelsPerUnit(
            axis: orientation == .vertical ? .vertical : .horizontal, ppi: ppi, canvas: canvas)
    }

    private func origin(_ orientation: GuideOrientation) -> CGFloat {
        orientation == .vertical ? rulerOrigin.x : rulerOrigin.y
    }

    /// The canvas centre on this orientation's axis, expressed FROM the
    /// ruler origin — the number a ruler would print there.
    private func seedValue(_ orientation: GuideOrientation) -> Double {
        let centre = CGFloat(orientation.extent(inCanvas: canvas) / 2)
        return unit.value(
            canvas: centre, origin: origin(orientation),
            pixelsPerUnit: pixelsPerUnit(orientation))
    }

    /// A typed number back in absolute canvas coordinates, which is what the
    /// core stores and what every MCP reply reports.
    private func canvasPosition(_ value: Double, _ orientation: GuideOrientation) -> Double {
        Double(
            unit.canvas(
                value: value, origin: origin(orientation),
                pixelsPerUnit: pixelsPerUnit(orientation)))
    }

    /// "0 to 8.5 in" — the legal typed range for one orientation, which
    /// moves with the ruler origin and so cannot be a constant in the hint.
    private func rangeText(_ orientation: GuideOrientation) -> String {
        let extent = orientation.extent(inCanvas: canvas)
        let low = unit.value(
            canvas: 0, origin: origin(orientation), pixelsPerUnit: pixelsPerUnit(orientation))
        let high = unit.value(
            canvas: CGFloat(extent), origin: origin(orientation),
            pixelsPerUnit: pixelsPerUnit(orientation))
        return "\(unit.label(low, step: 0.01)) to \(unit.label(high, step: 0.01)) "
            + unit.abbreviation
    }

    // MARK: - Actions

    /// The radio pair. Flipping the orientation re-seeds the position with
    /// the OTHER axis's centre.
    ///
    /// Re-seeding is deliberate: the two axes are different lengths and
    /// carry their own ppi and their own ruler origin, so a number that
    /// named the centre of one names an arbitrary place on the other. A
    /// number the USER typed is left alone — a flip must never throw away
    /// their input — which is what `seededText` is for.
    @objc private func orientationChanged(_ sender: Any?) {
        guard let sender = sender as? NSButton else { return }
        horizontalRadio.state = sender === horizontalRadio ? .on : .off
        verticalRadio.state = sender === verticalRadio ? .on : .off
        let current = selectedOrientation
        guard current != seededOrientation else { return }
        // Only ever replaces a number the sheet itself put there.
        let typed = positionField.stringValue != seededText
        seededOrientation = current
        guard !typed else { return }
        seed(current)
    }

    /// Writes the canvas centre for `orientation` into the field THROUGH the
    /// formatter, so what the field shows is what the field will parse back
    /// — a string built by hand would use "." on a locale that types ",".
    private func seed(_ orientation: GuideOrientation) {
        positionField.doubleValue = seedValue(orientation)
        seededText = positionField.stringValue
    }

    private var selectedOrientation: GuideOrientation {
        verticalRadio.state == .on ? .vertical : .horizontal
    }

    @objc private func applyClicked(_ sender: Any?) {
        let orientation = selectedOrientation
        // An empty field is not "0": the formatter would read it as one and
        // this sheet would silently place a guide on the ruler origin.
        guard !positionField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            NSSound.beep()
            return
        }
        let typed = positionField.doubleValue
        let position = canvasPosition(typed, orientation)
        let extent = orientation.extent(inCanvas: canvas)
        // Refused rather than clamped, and the sheet stays open: the number
        // is the user's exact request, and silently turning "12 in" into the
        // canvas edge would report a guide they did not ask for. The hint
        // above already states both ranges.
        guard typed.isFinite, position.isFinite, position >= 0, position <= extent else {
            NSSound.beep()
            return
        }
        dismiss(self)
        onCommit(orientation, position)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}
