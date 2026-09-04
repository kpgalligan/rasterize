import AppKit

/// Image > Apply Image…: one source (a layer or Merged, one of its planes
/// or a channel, optionally inverted) blended onto the current edit target
/// with a blend mode and an opacity, previewed live.
///
/// The TARGET is not a control. Apply Image writes wherever the editor is
/// already pointed — the active layer, one of its colour planes, or the
/// selected alpha channel — exactly as Photoshop applies to the active
/// channel; the footnote names it, and the Channels panel is where it
/// changes. A layer MASK is the one target the arithmetic is not defined
/// over, so Apply is disabled and the hint says why.
///
/// The math is `ChannelMath.applyImage`, shared with the `apply_image` MCP
/// tool; this file is the dialog, its preview and its commit, nothing else.
final class ApplyImageSheetController: NSViewController {
    private weak var editor: EditorViewController?
    private weak var canvas: ImageCanvasView?
    /// The handle the preview runs on, captured when the sheet opened: the
    /// PreviewRenderer closure runs on a background queue and must never
    /// reach into live document state (`AdjustSheetController`'s `baseDoc`
    /// rule). Apply re-runs the same math on the document's CURRENT handle.
    private let baseDoc: RasterDocument?
    /// The editor's edit target and layer, captured at open so a panel click
    /// behind the sheet cannot move the goalposts mid-dialog.
    private let target: PaintTarget
    private let targetLayer: Int

    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let planePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let invertCheckbox = NSButton(
        checkboxWithTitle: "Invert", target: nil, action: nil)
    private let blendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacitySlider = NSSlider(
        value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let opacityField = NSTextField(string: "100")
    private let renderer = PreviewRenderer()
    private var didRequestInitialPreview = false

    init(editor: EditorViewController) {
        self.editor = editor
        self.canvas = editor.canvas
        self.baseDoc = editor.document?.doc
        self.target = editor.paintTarget
        self.targetLayer = editor.document?.activeLayerIndex ?? 0
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ApplyImageSheetController does not support NSCoder")
    }

    override func loadView() {
        ChannelMathControls.fillSources(sourcePopup, baseDoc)
        ChannelMathControls.fillPlanes(planePopup, baseDoc)
        // Onto a colour plane or an alpha channel the result is ONE plane,
        // where the four HSL modes have no triple to work on and the core
        // refuses them; onto the layer they blend the three planes as one
        // colour and mean exactly what Photoshop means by them.
        ChannelMathControls.fillBlendModes(
            blendPopup, singlePlane: target.targetsPlaneOrChannel)
        for popup in [sourcePopup, planePopup, blendPopup] {
            popup.target = self
            popup.action = #selector(controlChanged(_:))
        }
        invertCheckbox.target = self
        invertCheckbox.action = #selector(controlChanged(_:))
        invertCheckbox.font = DS.sans(13)

        opacitySlider.target = self
        opacitySlider.action = #selector(sliderChanged(_:))
        opacityField.target = self
        opacityField.action = #selector(fieldChanged(_:))
        let opacityRow = ChannelMathControls.opacityRow(
            slider: opacitySlider, field: opacityField)

        let grid = NSGridView(views: [
            [fieldLabel("Source:"), sourcePopup],
            [fieldLabel("Channel:"), planePopup],
            [NSGridCell.emptyContentView, invertCheckbox],
            [fieldLabel("Blending:"), blendPopup],
            [fieldLabel("Opacity:"), opacityRow],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        syncSourceEnabled()
        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        applyButton.isEnabled = canApply
        view = makeSheetView(
            title: "Apply image", hint: hintText, content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton, leading: [sheetFootnote(footnoteText)]))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The defaults (Merged, RGB, Normal at 100%) are a real change, not
        // an identity like the adjustment sliders' zeroes, so what the user
        // sees on opening must already be what Apply would produce.
        guard !didRequestInitialPreview else { return }
        didRequestInitialPreview = true
        requestPreview()
    }

    // MARK: - State

    /// False for a mask target (the arithmetic has no meaning there), for a
    /// plane no write can reach — Luma and Mask are derived, and the core
    /// refuses them — and for a document that has gone out from under the
    /// sheet.
    private var canApply: Bool {
        guard baseDoc != nil, target.isPaintable else { return false }
        if case .mask = target { return false }
        return !targetsAdjustmentPixels
    }

    /// True when the target would write the PIXELS of an adjustment layer —
    /// which the compositor ignores, so the blend would land nowhere while
    /// registering a real undo step. The commit refuses it with an alert;
    /// this is the same rule, one step earlier, and the same rule the agent's
    /// apply_image already applied. A CHANNEL target is document state and is
    /// never affected.
    private var targetsAdjustmentPixels: Bool {
        guard baseDoc?.layerIsAdjustment(targetLayer) == true else { return false }
        switch target {
        case .layer, .plane: return true
        case .mask, .channel: return false
        }
    }

    private func parameters() -> ApplyImageParameters {
        ApplyImageParameters(
            source: ChannelMathControls.sourceLayer(sourcePopup),
            sourcePlane: ChannelMathControls.plane(planePopup),
            invert: invertCheckbox.state == .on,
            blend: ChannelMathControls.blendMode(blendPopup),
            opacity: ChannelMathControls.opacity(opacitySlider),
            target: target,
            targetLayer: targetLayer)
    }

    /// A channel source ignores the layer popup — a channel is document
    /// state, canvas-sized already, and `ChannelMath.sourcePlane` says so —
    /// so the popup goes grey rather than sit there looking meaningful.
    private func syncSourceEnabled() {
        if case .channel = ChannelMathControls.plane(planePopup) {
            sourcePopup.isEnabled = false
        } else {
            sourcePopup.isEnabled = true
        }
    }

    private var layerName: String {
        baseDoc?.layerInfo(targetLayer)?.name ?? "the active layer"
    }

    /// The target in words: the layer, and which of its planes when one is
    /// targeted.
    private var targetName: String {
        switch target {
        case .mask: return "layer mask"
        case .layer: return layerName
        case .plane(let plane): return "\(layerName) · \(plane.displayName)"
        case .channel(let index):
            return "Channel \(baseDoc?.channelInfo(index)?.name ?? String(index))"
        }
    }

    /// The bottom-left line naming what Apply will write. Apply Image has no
    /// target control, so this is the only place the answer appears — kept
    /// short because the footnote shares its row with the buttons.
    private var footnoteText: String {
        guard baseDoc != nil else { return "no document" }
        return canApply ? "Target: \(targetName)" : "\(targetName) — Apply disabled"
    }

    /// The wrapping hint carries the refusal in full — it is the one label
    /// in the card with room for a sentence.
    private var hintText: String {
        let base = "Blends one source onto the current target — the active layer, one of its "
            + "colour planes, or an alpha channel."
        guard baseDoc != nil, !canApply else { return base }
        if targetsAdjustmentPixels {
            return base + " \(layerName) is an adjustment layer: the compositor ignores its "
                + "pixels, so there is nothing to blend into. Target its mask, or another "
                + "layer."
        }
        return base + " The current target is not one of them, so Apply is disabled: pick "
            + "another row in the Channels panel first."
    }

    // MARK: - Preview

    /// The result as the canvas should show it: a layer target flattens, a
    /// plane or channel target draws its plane in grayscale — which
    /// `ChannelDisplay.drawBase` puts on screen because it draws
    /// `previewImage ?? base`, so a plane view never hides its own preview.
    private func requestPreview() {
        guard let baseDoc = baseDoc, canApply else { return }
        let parameters = self.parameters()
        renderer.request {
            // nil means either that the blend changed nothing (the core
            // refuses a write that moves no byte) or that a source is gone;
            // the honest preview of both is the untouched document, not a
            // blank canvas. Apply beeps on the second case.
            let result = ChannelMath.applyImage(baseDoc, parameters) ?? baseDoc
            switch parameters.target {
            case .layer, .mask:
                return result.flattened()?.makeCGImage()
            case .plane(let plane):
                guard let bytes = result.layerPlane(parameters.targetLayer, plane.rz) else {
                    return nil
                }
                return CanvasSelection.grayImage(bytes, result.width, result.height)
            case .channel(let index):
                guard let bytes = result.channelPlane(index) else { return nil }
                return CanvasSelection.grayImage(bytes, result.width, result.height)
            }
        }
    }

    // MARK: - Actions

    @objc private func controlChanged(_ sender: Any?) {
        syncSourceEnabled()
        requestPreview()
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
        guard canApply else {
            NSSound.beep()
            return
        }
        let parameters = self.parameters()
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        editor?.applyImage(parameters)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}
