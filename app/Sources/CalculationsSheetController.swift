import AppKit

/// Image > Calculations…: two source planes blended into a new plane, which
/// becomes an alpha channel or the selection. Source 1 is the BLEND layer
/// and Source 2 the BASE — Photoshop's convention, and the argument order
/// the core's plane arithmetic documents.
///
/// The math is `ChannelMath.calculated`, shared with the `calculations` MCP
/// tool; this file is the dialog, its preview and its commit. Unlike Apply
/// Image nothing here targets the picture: the result is a channel or a
/// selection either way, so no layer's pixels are at risk.
final class CalculationsSheetController: NSViewController {
    private weak var editor: EditorViewController?
    private weak var canvas: ImageCanvasView?
    /// The handle the preview runs on, captured when the sheet opened (the
    /// PreviewRenderer closure runs on a background queue). Apply re-runs
    /// the math on the document's CURRENT handle for the channel route.
    private let baseDoc: RasterDocument?
    /// The name a new channel takes when the field is left empty, resolved
    /// once at open so it cannot drift while the sheet is up.
    private let defaultName: String

    private let source1Popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let plane1Popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let invert1Checkbox = NSButton(
        checkboxWithTitle: "Invert", target: nil, action: nil)
    private let source2Popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let plane2Popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let invert2Checkbox = NSButton(
        checkboxWithTitle: "Invert", target: nil, action: nil)
    private let blendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacitySlider = NSSlider(
        value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let opacityField = NSTextField(string: "100")
    private let resultPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(string: "")
    private let renderer = PreviewRenderer()
    private var didRequestInitialPreview = false

    init(editor: EditorViewController) {
        self.editor = editor
        self.canvas = editor.canvas
        self.baseDoc = editor.document?.doc
        self.defaultName = editor.document?.doc?.nextChannelName ?? "Alpha 1"
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CalculationsSheetController does not support NSCoder")
    }

    override func loadView() {
        let source1 = sourceGrid(
            layer: source1Popup, plane: plane1Popup, invert: invert1Checkbox)
        let source2 = sourceGrid(
            layer: source2Popup, plane: plane2Popup, invert: invert2Checkbox)

        // Calculations always produces ONE plane, so the four HSL modes —
        // which need an RGB triple — are not offered (the core refuses them
        // there; see RzBlendMode.grayDegenerateModes).
        ChannelMathControls.fillBlendModes(blendPopup, singlePlane: true)
        blendPopup.target = self
        blendPopup.action = #selector(controlChanged(_:))

        opacitySlider.target = self
        opacitySlider.action = #selector(sliderChanged(_:))
        opacityField.target = self
        opacityField.action = #selector(fieldChanged(_:))
        let opacityRow = ChannelMathControls.opacityRow(
            slider: opacitySlider, field: opacityField)

        resultPopup.addItems(withTitles: ["New Channel", "Selection"])
        resultPopup.selectItem(at: 0)
        resultPopup.target = self
        resultPopup.action = #selector(resultChanged(_:))
        ChannelMathControls.style(resultPopup)

        nameField.stringValue = defaultName
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        DSField.style(nameField)

        let tail = NSGridView(views: [
            [fieldLabel("Blending:"), blendPopup],
            [fieldLabel("Opacity:"), opacityRow],
            [fieldLabel("Result:"), resultPopup],
            [fieldLabel("Name:"), nameField],
        ])
        tail.rowSpacing = 10
        tail.columnSpacing = 12
        tail.column(at: 0).xPlacement = .trailing
        tail.column(at: 0).width = 106

        let blockViews: [NSView] = [
            microHeader("Source 1"), source1, microHeader("Source 2"), source2, tail,
        ]
        let content = NSStackView(views: blockViews)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        // A little air before each section header, so the two source blocks
        // read as blocks rather than as one eight-row grid.
        content.setCustomSpacing(16, after: source1)
        content.setCustomSpacing(16, after: source2)

        syncResultState()
        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        applyButton.isEnabled = baseDoc != nil
        view = makeSheetView(
            title: "Calculations",
            hint: "Blends two source planes into a new one. Source 1 is the blend layer, "
                + "Source 2 the base it is applied to. The result becomes an alpha channel "
                + "or the selection — no layer's pixels change.",
            content: content,
            buttonRow: makeButtonRow(cancel: cancelButton, apply: applyButton))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Both sources default to Merged/RGB, so the opening state already
        // computes a real plane: show it rather than an empty canvas.
        guard !didRequestInitialPreview else { return }
        didRequestInitialPreview = true
        requestPreview()
    }

    // MARK: - Layout pieces

    /// One source block: the layer it reads, the plane within it, and the
    /// invert switch. Both blocks are built by this one function so they can
    /// never drift apart.
    private func sourceGrid(
        layer: NSPopUpButton, plane: NSPopUpButton, invert: NSButton
    ) -> NSGridView {
        ChannelMathControls.fillSources(layer, baseDoc)
        ChannelMathControls.fillPlanes(plane, baseDoc)
        for popup in [layer, plane] {
            popup.target = self
            popup.action = #selector(controlChanged(_:))
        }
        invert.target = self
        invert.action = #selector(controlChanged(_:))
        invert.font = DS.sans(13)

        let grid = NSGridView(views: [
            [fieldLabel("Layer:"), layer],
            [fieldLabel("Channel:"), plane],
            [NSGridCell.emptyContentView, invert],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106
        return grid
    }

    private func microHeader(_ title: String) -> NSTextField {
        NSTextField(labelWithAttributedString: DS.microLabel(title))
    }

    // MARK: - State

    private var selectedResult: CalculationsResult {
        resultPopup.indexOfSelectedItem == 1 ? .selection : .newChannel
    }

    private func parameters() -> CalculationsParameters {
        CalculationsParameters(
            source1: CalculationsParameters.Source(
                layer: ChannelMathControls.sourceLayer(source1Popup),
                plane: ChannelMathControls.plane(plane1Popup),
                invert: invert1Checkbox.state == .on),
            source2: CalculationsParameters.Source(
                layer: ChannelMathControls.sourceLayer(source2Popup),
                plane: ChannelMathControls.plane(plane2Popup),
                invert: invert2Checkbox.state == .on),
            blend: ChannelMathControls.blendMode(blendPopup),
            opacity: ChannelMathControls.opacity(opacitySlider),
            name: resolvedName)
    }

    /// The typed name, or the "Alpha N" the document offered at open — an
    /// empty name would make an unnameable row in the panel.
    private var resolvedName: String {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? defaultName : typed
    }

    /// The name only means anything for a new channel; a selection result
    /// leaves the field grey rather than pretending it will be used. A
    /// channel source likewise ignores its layer popup (a channel is
    /// document state, canvas-sized already — `ChannelMath.sourcePlane`).
    private func syncResultState() {
        nameField.isEnabled = selectedResult == .newChannel
        for (source, plane) in [(source1Popup, plane1Popup), (source2Popup, plane2Popup)] {
            if case .channel = ChannelMathControls.plane(plane) {
                source.isEnabled = false
            } else {
                source.isEnabled = true
            }
        }
    }

    // MARK: - Preview

    /// The computed plane, in grayscale, on the canvas — what the new
    /// channel will hold, or what the selection will cover. It is pushed
    /// through `canvas.previewImage` like every other sheet's preview, so
    /// Apply and Cancel clear it the same way.
    private func requestPreview() {
        guard let baseDoc = baseDoc else { return }
        let parameters = self.parameters()
        renderer.request {
            guard let plane = ChannelMath.calculated(baseDoc, parameters) else { return nil }
            return CanvasSelection.grayImage(plane, baseDoc.width, baseDoc.height)
        }
    }

    // MARK: - Actions

    @objc private func controlChanged(_ sender: Any?) {
        syncResultState()
        requestPreview()
    }

    @objc private func resultChanged(_ sender: Any?) {
        // The plane is the same either way; only what becomes of it changes.
        syncResultState()
    }

    @objc private func sliderChanged(_ sender: Any?) {
        ChannelMathControls.syncField(opacityField, to: opacitySlider)
        requestPreview()
    }

    @objc private func fieldChanged(_ sender: Any?) {
        ChannelMathControls.syncSlider(opacitySlider, to: opacityField)
        requestPreview()
    }

    @objc private func applyClicked(_ sender: Any?) {
        guard baseDoc != nil else {
            NSSound.beep()
            return
        }
        let parameters = self.parameters()
        let result = selectedResult
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        editor?.calculations(parameters, result: result)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}
