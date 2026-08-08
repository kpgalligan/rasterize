import AppKit

// MARK: - PreviewRenderer

/// Debounced, coalescing background renderer shared by the live-preview
/// sheets. Requests made while a render is in flight replace any queued one;
/// only the newest pending request runs next.
final class PreviewRenderer {
    private let queue = DispatchQueue(label: "com.rasterize.preview")
    private var pending: (() -> CGImage?)?
    private var isRendering = false
    private var debounce: DispatchWorkItem?

    var onRender: ((CGImage?) -> Void)?

    func request(_ compute: @escaping () -> CGImage?) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pending = compute
            self.drain()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    func cancel() {
        debounce?.cancel()
        debounce = nil
        pending = nil
        onRender = nil
        // Wait out any in-flight compute: RzImage handles are not thread-safe,
        // and after cancel() returns the caller may touch the same handle on
        // the main thread (Apply). The queue only hops back to main
        // asynchronously, so this cannot deadlock.
        queue.sync {}
    }

    private func drain() {
        guard !isRendering, let compute = pending else { return }
        pending = nil
        isRendering = true
        queue.async { [weak self] in
            let result = compute()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRendering = false
                self.onRender?(result)
                self.drain()
            }
        }
    }
}

// MARK: - Shared layout helpers

private let sheetWidth: CGFloat = 380
private let sheetInset: CGFloat = 20

private func makeSheetView(grid: NSGridView, buttonRow: NSStackView) -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: sheetWidth, height: 240))
    grid.translatesAutoresizingMaskIntoConstraints = false
    buttonRow.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(grid)
    container.addSubview(buttonRow)
    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: sheetWidth),
        grid.topAnchor.constraint(equalTo: container.topAnchor, constant: sheetInset),
        grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: sheetInset),
        grid.trailingAnchor.constraint(
            lessThanOrEqualTo: container.trailingAnchor, constant: -sheetInset),
        buttonRow.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: sheetInset),
        buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: sheetInset),
        buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -sheetInset),
        buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -sheetInset),
    ])
    return container
}

private func makeButtonRow(
    cancel: NSButton, apply: NSButton, leading: [NSView] = []
) -> NSStackView {
    cancel.keyEquivalent = "\u{1b}"
    apply.keyEquivalent = "\r"
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
    let row = NSStackView(views: leading + [spacer, cancel, apply])
    row.orientation = .horizontal
    row.spacing = 8
    return row
}

private func fieldLabel(_ text: String) -> NSTextField {
    NSTextField(labelWithString: text)
}

// MARK: - ResizeSheetController

final class ResizeSheetController: NSViewController, NSTextFieldDelegate {
    private let document: ImageDocument
    private let originalWidth: Int
    private let originalHeight: Int

    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")
    private let lockCheckbox = NSButton(
        checkboxWithTitle: "Lock aspect ratio", target: nil, action: nil)
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private static let filters: [(title: String, value: RzResizeFilter)] = [
        ("Nearest", RZ_FILTER_NEAREST),
        ("Bilinear", RZ_FILTER_BILINEAR),
        ("Catmull-Rom", RZ_FILTER_CATMULL_ROM),
        ("Lanczos3", RZ_FILTER_LANCZOS3),
    ]

    init(document: ImageDocument) {
        self.document = document
        self.originalWidth = document.image?.width ?? 1
        self.originalHeight = document.image?.height ?? 1
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ResizeSheetController does not support NSCoder")
    }

    override func loadView() {
        for field in [widthField, heightField] {
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.allowsFloats = false
            formatter.minimum = 1
            formatter.maximum = 20000
            field.formatter = formatter
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        widthField.integerValue = originalWidth
        heightField.integerValue = originalHeight
        lockCheckbox.state = .on

        filterPopup.addItems(withTitles: Self.filters.map { $0.title })
        filterPopup.selectItem(at: Self.filters.count - 1) // Lanczos3

        let currentLabel = fieldLabel("\(originalWidth) × \(originalHeight) px")
        currentLabel.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [fieldLabel("Current size:"), currentLabel],
            [fieldLabel("Width:"), widthField],
            [fieldLabel("Height:"), heightField],
            [NSGridCell.emptyContentView, lockCheckbox],
            [fieldLabel("Filter:"), filterPopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        let cancelButton = NSButton(
            title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        let applyButton = NSButton(
            title: "Apply", target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(grid: grid, buttonRow: makeButtonRow(cancel: cancelButton, apply: applyButton))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard lockCheckbox.state == .on,
              let field = obj.object as? NSTextField,
              originalWidth > 0, originalHeight > 0
        else { return }
        let aspect = Double(originalHeight) / Double(originalWidth)
        if field === widthField {
            let w = widthField.integerValue
            if w > 0 {
                heightField.integerValue = max(1, Int((Double(w) * aspect).rounded()))
            }
        } else if field === heightField {
            let h = heightField.integerValue
            if h > 0 {
                widthField.integerValue = max(1, Int((Double(h) / aspect).rounded()))
            }
        }
    }

    @objc private func applyClicked(_ sender: Any?) {
        let w = widthField.integerValue
        let h = heightField.integerValue
        let index = max(0, min(filterPopup.indexOfSelectedItem, Self.filters.count - 1))
        let filter = Self.filters[index].value
        guard w >= 1, h >= 1 else {
            NSSound.beep()
            return
        }
        guard w * h <= RasterImage.maxResizePixels else {
            let alert = NSAlert()
            alert.messageText = "Size Too Large"
            alert.informativeText =
                "The resized image cannot exceed 100 megapixels (width × height ≤ 100,000,000)."
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        dismiss(self)
        document.applyEdit("Resize") { $0.resized(w: w, h: h, filter: filter) }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}

// MARK: - AdjustSheetController

final class AdjustSheetController: NSViewController {
    private let document: ImageDocument
    private weak var canvas: ImageCanvasView?
    private let base: RasterImage?
    private let renderer = PreviewRenderer()

    private let brightnessSlider = NSSlider(
        value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let contrastSlider = NSSlider(
        value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let saturationSlider = NSSlider(
        value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let brightnessValue = NSTextField(labelWithString: "0.00")
    private let contrastValue = NSTextField(labelWithString: "0.00")
    private let saturationValue = NSTextField(labelWithString: "0.00")

    init(document: ImageDocument, canvas: ImageCanvasView) {
        self.document = document
        self.canvas = canvas
        self.base = document.image
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AdjustSheetController does not support NSCoder")
    }

    override func loadView() {
        for slider in [brightnessSlider, contrastSlider, saturationSlider] {
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }
        for label in [brightnessValue, contrastValue, saturationValue] {
            label.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }

        let grid = NSGridView(views: [
            [fieldLabel("Brightness:"), brightnessSlider, brightnessValue],
            [fieldLabel("Contrast:"), contrastSlider, contrastValue],
            [fieldLabel("Saturation:"), saturationSlider, saturationValue],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetClicked(_:)))
        let cancelButton = NSButton(
            title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        let applyButton = NSButton(
            title: "Apply", target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            grid: grid,
            buttonRow: makeButtonRow(cancel: cancelButton, apply: applyButton, leading: [resetButton]))
    }

    private func updateValueLabels() {
        brightnessValue.stringValue = String(format: "%.2f", brightnessSlider.doubleValue)
        contrastValue.stringValue = String(format: "%.2f", contrastSlider.doubleValue)
        saturationValue.stringValue = String(format: "%.2f", saturationSlider.doubleValue)
    }

    private func requestPreview() {
        guard let base = base else { return }
        let brightness = brightnessSlider.doubleValue
        let contrast = contrastSlider.doubleValue
        let saturation = saturationSlider.doubleValue
        renderer.request {
            base.adjusted(brightness: brightness, contrast: contrast, saturation: saturation)?
                .makeCGImage()
        }
    }

    @objc private func sliderChanged(_ sender: Any?) {
        updateValueLabels()
        requestPreview()
    }

    @objc private func resetClicked(_ sender: Any?) {
        brightnessSlider.doubleValue = 0
        contrastSlider.doubleValue = 0
        saturationSlider.doubleValue = 0
        updateValueLabels()
        requestPreview()
    }

    @objc private func applyClicked(_ sender: Any?) {
        let brightness = brightnessSlider.doubleValue
        let contrast = contrastSlider.doubleValue
        let saturation = saturationSlider.doubleValue
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        // Compose on the document's CURRENT image, not the captured preview
        // base, so any edit that slipped in while the sheet was open survives.
        document.applyEdit("Adjust Colors") {
            $0.adjusted(brightness: brightness, contrast: contrast, saturation: saturation)
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}

// MARK: - BlurSheetController

final class BlurSheetController: NSViewController {
    private let document: ImageDocument
    private weak var canvas: ImageCanvasView?
    private let base: RasterImage?
    private let renderer = PreviewRenderer()

    private let sigmaSlider = NSSlider(
        value: 2, minValue: 0.5, maxValue: 25, target: nil, action: nil)
    private let sigmaValue = NSTextField(labelWithString: "2.0")

    init(document: ImageDocument, canvas: ImageCanvasView) {
        self.document = document
        self.canvas = canvas
        self.base = document.image
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BlurSheetController does not support NSCoder")
    }

    override func loadView() {
        sigmaSlider.isContinuous = true
        sigmaSlider.target = self
        sigmaSlider.action = #selector(sliderChanged(_:))
        sigmaSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        sigmaValue.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        sigmaValue.alignment = .right
        sigmaValue.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let grid = NSGridView(views: [
            [fieldLabel("Radius (sigma):"), sigmaSlider, sigmaValue]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        let cancelButton = NSButton(
            title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        let applyButton = NSButton(
            title: "Apply", target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(grid: grid, buttonRow: makeButtonRow(cancel: cancelButton, apply: applyButton))
    }

    private func requestPreview() {
        guard let base = base else { return }
        let sigma = sigmaSlider.doubleValue
        renderer.request {
            base.blurred(sigma: sigma)?.makeCGImage()
        }
    }

    @objc private func sliderChanged(_ sender: Any?) {
        sigmaValue.stringValue = String(format: "%.1f", sigmaSlider.doubleValue)
        requestPreview()
    }

    @objc private func applyClicked(_ sender: Any?) {
        let sigma = sigmaSlider.doubleValue
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        document.applyEdit("Gaussian Blur") { $0.blurred(sigma: sigma) }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}
