import AppKit

/// The destructive Levels dialog (Image ▸ Adjustments ▸ Levels…): the three
/// slider rows `SliderSheetController.levels` used to build, now under the
/// histogram of the tones they move.
///
/// It is its own controller rather than another `SliderSheetController`
/// factory for one reason: the generic sheet builds a bare grid, and Levels
/// is the one destructive dialog whose controls mean nothing without the
/// plot behind them. Everything else is that class's contract, kept
/// deliberately identical — the log-feel gamma map, the black < white push,
/// the plane capture, the debounced in-context preview and the teardown
/// order — because the two dialogs must still feel like one app.
final class LevelsSheetController: NSViewController {
    private let document: ImageDocument
    private weak var canvas: ImageCanvasView?
    private let baseDoc: RasterDocument?
    private let layerIndex: Int
    private let baseLayer: RasterImage?
    /// The plane a plane/channel target previews on, captured ONCE here:
    /// extracting it is a canvas-sized read, so doing it per slider tick,
    /// ahead of the debounce and on the main thread, would hang the dialog
    /// on a large image.
    private let planePreview: PlanePreview?
    /// The plot behind the sliders, filled when its bins arrive: the tones
    /// they move are the LAYER being filtered, not the composite, because
    /// that is what Apply rewrites. Captured once at open and on a
    /// background queue — a canvas-sized scan inside `init` would freeze
    /// the UI before the sheet appeared (`Histogram.loadForSheet`).
    private let plot = HistogramView(frame: .zero)
    private let renderer = PreviewRenderer()

    private let blackSlider = NSSlider(value: 0, minValue: 0, maxValue: 0.99,
                                       target: nil, action: nil)
    private let whiteSlider = NSSlider(value: 1, minValue: 0.01, maxValue: 1,
                                       target: nil, action: nil)
    // Log-feel gamma: the slider runs -1…1 and maps to 10^x, so 0.1, 1 and
    // 10 sit at the left edge, the centre and the right edge.
    private let gammaSlider = NSSlider(value: 0, minValue: -1, maxValue: 1,
                                       target: nil, action: nil)
    private let blackLabel = NSTextField(labelWithString: "0.00")
    private let whiteLabel = NSTextField(labelWithString: "1.00")
    private let gammaLabel = NSTextField(labelWithString: "1.00")
    private var didRequestInitialPreview = false

    init(document: ImageDocument, canvas: ImageCanvasView) {
        self.document = document
        self.canvas = canvas
        self.baseDoc = document.doc
        self.layerIndex = document.activeLayerIndex
        self.baseLayer = document.doc?.layerImage(document.activeLayerIndex)
        self.planePreview = document.targetPlanePreview()
        super.init(nibName: nil, bundle: nil)
        Histogram.loadForSheet(
            document, mode: .destructive, destructiveLayer: document.activeLayerIndex
        ) { [weak self] bins in
            self?.plot.bins = bins
        }
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LevelsSheetController does not support NSCoder")
    }

    override func loadView() {
        plot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            plot.widthAnchor.constraint(equalToConstant: 256),
            plot.heightAnchor.constraint(equalToConstant: 72),
        ])

        var rows: [[NSView]] = []
        for (label, slider, readout) in [
            ("Black:", blackSlider, blackLabel),
            ("White:", whiteSlider, whiteLabel),
            ("Gamma:", gammaSlider, gammaLabel),
        ] {
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            readout.font = DS.mono(12)
            readout.textColor = DS.textMuted
            readout.alignment = .right
            readout.widthAnchor.constraint(equalToConstant: 52).isActive = true
            rows.append([fieldLabel(label), slider, readout])
        }
        let grid = AdjustmentSheet.grid(rows)

        let content = NSStackView(views: [plot, grid])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Levels", content: content,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("gamma > 1 brightens · one undo")]))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The defaults are the identity, but the preview still runs once so
        // a plane target shows its plane rather than the last thing drawn.
        guard !didRequestInitialPreview else { return }
        didRequestInitialPreview = true
        requestPreview()
    }

    private var values: (black: Double, white: Double, gamma: Double) {
        (blackSlider.doubleValue, whiteSlider.doubleValue, pow(10, gammaSlider.doubleValue))
    }

    private func requestPreview() {
        guard let baseDoc = baseDoc, let baseLayer = baseLayer else { return }
        let values = self.values
        let idx = layerIndex
        // A plane target previews the SAME op on that plane, on the handle
        // captured in init (AdjustSheetController's rule).
        let planePreview = self.planePreview
        renderer.request {
            let levels: (RasterImage) -> RasterImage? = {
                $0.levels(black: values.black, white: values.white, gamma: values.gamma)
            }
            if let planePreview = planePreview {
                return planePreview.preview(levels)
            }
            guard let filtered = levels(baseLayer),
                  let previewDoc = baseDoc.withLayerPixels(idx, filtered)
            else { return nil }
            return previewDoc.flattened()?.makeCGImage(in: baseDoc.colorSpace)
        }
    }

    @objc private func sliderChanged(_ sender: Any?) {
        // Keep black < white by pushing the OTHER slider along.
        if sender as AnyObject === blackSlider, whiteSlider.doubleValue <= blackSlider.doubleValue {
            whiteSlider.doubleValue = min(blackSlider.doubleValue + 0.01, 1)
        } else if sender as AnyObject === whiteSlider,
            blackSlider.doubleValue >= whiteSlider.doubleValue
        {
            blackSlider.doubleValue = max(whiteSlider.doubleValue - 0.01, 0)
        }
        blackLabel.stringValue = String(format: "%.2f", blackSlider.doubleValue)
        whiteLabel.stringValue = String(format: "%.2f", whiteSlider.doubleValue)
        gammaLabel.stringValue = String(format: "%.2f", pow(10, gammaSlider.doubleValue))
        requestPreview()
    }

    @objc private func applyClicked(_ sender: Any?) {
        let values = self.values
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        document.applyToActiveLayer(
            "Levels",
            record: .filter(
                "levels",
                [
                    "black": ActionArgs.number(values.black),
                    "white": ActionArgs.number(values.white),
                    "gamma": ActionArgs.number(values.gamma),
                ],
                target: document.planeEditTarget.layerEditAgentName(in: document.doc))
        ) {
            $0.levels(black: values.black, white: values.white, gamma: values.gamma)
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}
