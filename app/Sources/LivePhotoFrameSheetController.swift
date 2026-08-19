import AppKit

/// The frame picker for a LIVE PHOTO layer (Layer > Select Live Photo
/// Frame…, the layers panel's row menu, and a double-click on the row): a
/// slider over the clip's timeline, previewed on the canvas exactly like the
/// filter sheets preview theirs, committing the chosen moment as one undo
/// step.
///
/// It is its own file rather than another section of Sheets.swift because
/// that file is frozen at its current size; it is built from the same shared
/// `makeSheetView` pieces, so it matches every other dialog.
final class LivePhotoFrameSheetController: NSViewController {
    private let document: ImageDocument
    private weak var canvas: ImageCanvasView?

    /// The layer being scrubbed, and the description it started from. Both
    /// are captured: the sheet blocks every other edit while it is open, and
    /// Cancel must leave exactly this state behind.
    private let layerIndex: Int
    private let original: LivePhotoPayload

    // In-context preview, the AdjustSheetController pattern: the chosen frame
    // is swapped into the captured doc handle and the flattened result is
    // shown, so the other layers, the blend mode and the mask stay visible
    // while scrubbing. The handle is read only on the renderer's queue, and
    // its cancel() waits out any in-flight render before Apply touches the
    // document on the main thread.
    private let baseDoc: RasterDocument?
    private let renderer = PreviewRenderer()

    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let readout = NSTextField(labelWithString: "")

    /// The moment currently shown, always a value `settingTime` produced —
    /// clamped into the clip and snapped to the key moment.
    private var payload: LivePhotoPayload

    init(document: ImageDocument, canvas: ImageCanvasView?, layer: Int, payload: LivePhotoPayload) {
        self.document = document
        self.canvas = canvas
        self.layerIndex = layer
        self.original = payload
        self.payload = payload
        self.baseDoc = document.doc
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LivePhotoFrameSheetController does not support NSCoder")
    }

    override func loadView() {
        slider.minValue = 0
        slider.maxValue = original.duration
        slider.doubleValue = original.time
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.widthAnchor.constraint(equalToConstant: 240).isActive = true

        readout.font = DS.mono(11)
        readout.textColor = DS.textMuted

        let grid = NSGridView(views: [[fieldLabel("Moment:"), slider]])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        // The readout sits UNDER the grid rather than in its second column:
        // at the key frame it is long enough to run past the sheet's edge
        // from an indented start.
        let content = NSStackView(views: [grid, readout])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8

        let keyFrameButton = StickerButton(
            title: "Key Frame", style: .secondary, target: self,
            action: #selector(keyFrameClicked(_:)))
        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Select frame",
            hint: "Frames come from the Live Photo's clip, scaled to the photo's size; at the "
                + "key frame the layer shows the full-resolution photo itself.",
            content: content,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton, leading: [keyFrameButton]))
        updateReadout()
    }

    private func updateReadout() {
        readout.stringValue = LivePhoto.frameDescription(payload)
    }

    /// Renders the chosen frame into the captured document and shows the
    /// flattened result on the canvas. Decoding happens on the renderer's
    /// queue — a 12 MP still is not something to decode on the main thread
    /// per slider tick — and requests coalesce, so a fast scrub only renders
    /// the moments it settles on.
    private func requestPreview() {
        guard let baseDoc = baseDoc else { return }
        let payload = self.payload
        let idx = layerIndex
        renderer.request {
            guard let raster = LivePhoto.render(payload),
                  let previewDoc = baseDoc.withLayerPixels(
                    idx, rgba: raster.pixels, width: raster.width, height: raster.height)
            else { return nil }
            return previewDoc.flattened()?.makeCGImage()
        }
    }

    @objc private func sliderChanged(_ sender: Any?) {
        let updated = payload.settingTime(slider.doubleValue)
        guard updated != payload else { return }
        payload = updated
        updateReadout()
        requestPreview()
    }

    /// Back to the moment the photo was taken — the one position on the
    /// timeline where the layer shows the full-resolution still.
    @objc private func keyFrameClicked(_ sender: Any?) {
        slider.doubleValue = payload.keyTime
        sliderChanged(sender)
    }

    @objc private func applyClicked(_ sender: Any?) {
        let seconds = payload.time
        let idx = layerIndex
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        // Choosing the moment already showing is not an edit: no undo step,
        // no dirty flag, and no beep from applyEdit's nil path.
        guard seconds != original.time else { return }
        document.applyEdit("Select Live Photo Frame") {
            $0.settingLivePhotoFrame(idx, seconds: seconds)
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}
