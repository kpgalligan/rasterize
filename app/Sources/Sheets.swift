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
        // Wait out any in-flight compute: Rz handles are not thread-safe,
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
//
// Module-wide, not file-private: a dialog too big to live here is its own
// …SheetController file (LivePhotoFrameSheetController), and it must be
// built from these same pieces or the sheets stop matching each other.

let sheetWidth: CGFloat = 420
let sheetInset: CGFloat = 22

/// Assembles a design-system sheet: 420px card, 15px/700 title, optional
/// 12px muted hint, content, then the button row.
func makeSheetView(
    title: String? = nil, hint: String? = nil, content: NSView, buttonRow: NSStackView
) -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: sheetWidth, height: 240))
    container.wantsLayer = true
    container.layer?.backgroundColor = DS.chromeBackground.cgColor

    var stackedViews: [NSView] = []
    if let title = title {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DS.sans(15, weight: .bold)
        titleLabel.textColor = DS.textStrong
        stackedViews.append(titleLabel)
    }
    if let hint = hint {
        let hintLabel = NSTextField(wrappingLabelWithString: hint)
        hintLabel.font = DS.sans(12)
        hintLabel.textColor = DS.textMuted
        hintLabel.isEditable = false
        hintLabel.preferredMaxLayoutWidth = sheetWidth - sheetInset * 2
        stackedViews.append(hintLabel)
    }
    stackedViews.append(content)
    let stack = NSStackView(views: stackedViews)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.setCustomSpacing(16, after: stackedViews[stackedViews.count - 2])

    stack.translatesAutoresizingMaskIntoConstraints = false
    buttonRow.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    container.addSubview(buttonRow)
    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: sheetWidth),
        stack.topAnchor.constraint(equalTo: container.topAnchor, constant: sheetInset),
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: sheetInset),
        stack.trailingAnchor.constraint(
            lessThanOrEqualTo: container.trailingAnchor, constant: -sheetInset),
        buttonRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: sheetInset),
        buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: sheetInset),
        buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -sheetInset),
        buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -sheetInset),
    ])
    return container
}

func makeButtonRow(
    cancel: NSButton, apply: NSButton, leading: [NSView] = []
) -> NSStackView {
    cancel.keyEquivalent = "\u{1b}"
    apply.keyEquivalent = "\r"
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
    let row = NSStackView(views: leading + [spacer, cancel, apply])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
}

/// 13px row label for the sheet grids' 106px right-aligned label column.
func fieldLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = DS.sans(13)
    label.textColor = DS.textStrong
    return label
}

/// Bottom-left 10px mono footnote carried in the button row's leading slot.
func sheetFootnote(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = DS.mono(10)
    label.textColor = DS.textFaint
    return label
}

func sheetCancelButton(target: AnyObject, action: Selector) -> NSButton {
    StickerButton(title: "Cancel", style: .secondary, target: target, action: action)
}

func sheetApplyButton(target: AnyObject, action: Selector) -> NSButton {
    StickerButton(title: "Apply", style: .primary, target: target, action: action)
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
        self.originalWidth = document.doc?.width ?? 1
        self.originalHeight = document.doc?.height ?? 1
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
            DSField.style(field)
        }
        widthField.integerValue = originalWidth
        heightField.integerValue = originalHeight
        lockCheckbox.state = .on

        filterPopup.addItems(withTitles: Self.filters.map { $0.title })
        filterPopup.selectItem(at: Self.filters.count - 1) // Lanczos3
        filterPopup.font = DS.sans(13)

        let currentLabel = fieldLabel("\(originalWidth) × \(originalHeight) px")
        currentLabel.font = DS.mono(13)
        currentLabel.textColor = DS.textMuted

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
        grid.column(at: 0).width = 106

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Image size", content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("max 100 MP")]))
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
        document.applyEdit("Image Size") { $0.resized(w: w, h: h, filter: filter) }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}

// MARK: - CanvasSizeSheetController

/// The 3x3 anchor grid from Photoshop's Canvas Size dialog: the selected
/// cell marks where the existing content is pinned in the new canvas, and
/// neighboring cells show arrows pointing away from it.
private final class AnchorGridView: NSView {
    /// (column, row), 0-based, top-left origin. Center by default.
    private(set) var anchor = (col: 1, row: 1)

    private var buttons: [[NSButton]] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 2
        grid.columnSpacing = 2
        for row in 0..<3 {
            var rowButtons: [NSButton] = []
            for col in 0..<3 {
                let button = NSButton(title: "", target: self, action: #selector(cellClicked(_:)))
                button.setButtonType(.momentaryPushIn)
                button.isBordered = false
                button.wantsLayer = true
                button.layer?.cornerRadius = 4
                button.layer?.borderWidth = 1
                button.font = NSFont.systemFont(ofSize: 13)
                button.tag = row * 3 + col
                button.widthAnchor.constraint(equalToConstant: 32).isActive = true
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                rowButtons.append(button)
            }
            buttons.append(rowButtons)
            grid.addRow(with: rowButtons)
        }
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        refreshCells()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AnchorGridView does not support NSCoder")
    }

    @objc private func cellClicked(_ sender: NSButton) {
        anchor = (col: sender.tag % 3, row: sender.tag / 3)
        refreshCells()
    }

    private func refreshCells() {
        // Arrows radiate outward from the anchor; distant cells stay blank.
        let arrows: [[String]] = [
            ["↖", "↑", "↗"],
            ["←", "·", "→"],
            ["↙", "↓", "↘"],
        ]
        for row in 0..<3 {
            for col in 0..<3 {
                let button = buttons[row][col]
                let isAnchor = row == anchor.row && col == anchor.col
                let glyph: String
                if isAnchor {
                    glyph = "●"
                } else if abs(row - anchor.row) <= 1 && abs(col - anchor.col) <= 1 {
                    glyph = arrows[row - anchor.row + 1][col - anchor.col + 1]
                } else {
                    glyph = ""
                }
                button.layer?.borderColor = DS.borderStrong.cgColor
                button.layer?.backgroundColor =
                    (isAnchor ? DS.accent : DS.chromeBackground).cgColor
                button.attributedTitle = NSAttributedString(
                    string: glyph,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: isAnchor ? 10 : 13),
                        .foregroundColor: isAnchor ? DS.onAccent : DS.textMuted,
                    ])
            }
        }
    }
}

final class CanvasSizeSheetController: NSViewController {
    private let document: ImageDocument
    private let originalWidth: Int
    private let originalHeight: Int

    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")
    private let anchorGrid = AnchorGridView(frame: .zero)

    init(document: ImageDocument) {
        self.document = document
        self.originalWidth = document.doc?.width ?? 1
        self.originalHeight = document.doc?.height ?? 1
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasSizeSheetController does not support NSCoder")
    }

    override func loadView() {
        for field in [widthField, heightField] {
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.allowsFloats = false
            formatter.minimum = 1
            formatter.maximum = 20000
            field.formatter = formatter
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            DSField.style(field)
        }
        widthField.integerValue = originalWidth
        heightField.integerValue = originalHeight

        let currentLabel = fieldLabel("\(originalWidth) × \(originalHeight) px")
        currentLabel.font = DS.mono(13)
        currentLabel.textColor = DS.textMuted

        let grid = NSGridView(views: [
            [fieldLabel("Current size:"), currentLabel],
            [fieldLabel("Width:"), widthField],
            [fieldLabel("Height:"), heightField],
            [fieldLabel("Anchor:"), anchorGrid],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106
        grid.cell(for: anchorGrid)?.yPlacement = .top

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Canvas size",
            hint: "Grows or trims the canvas without scaling. Layers keep "
                + "their pixels and can be revealed again later.",
            content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("⌥⌘C")]))
    }

    @objc private func applyClicked(_ sender: Any?) {
        let w = widthField.integerValue
        let h = heightField.integerValue
        guard w >= 1, h >= 1 else {
            NSSound.beep()
            return
        }
        guard w * h <= RasterImage.maxResizePixels else {
            let alert = NSAlert()
            alert.messageText = "Size Too Large"
            alert.informativeText =
                "The canvas cannot exceed 100 megapixels (width × height ≤ 100,000,000)."
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        // The anchor pins the existing content: its column/row chooses how
        // much of the size delta lands left/above the old canvas origin.
        let fx = Double(anchorGrid.anchor.col) / 2.0
        let fy = Double(anchorGrid.anchor.row) / 2.0
        let originX = Int((Double(w - originalWidth) * fx).rounded())
        let originY = Int((Double(h - originalHeight) * fy).rounded())
        dismiss(self)
        guard w != originalWidth || h != originalHeight else { return }
        document.applyEdit("Canvas Size") {
            $0.canvasResized(w: w, h: h, originX: originX, originY: originY)
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}

// MARK: - AdjustSheetController

final class AdjustSheetController: NSViewController {
    private let document: ImageDocument
    private weak var canvas: ImageCanvasView?
    // In-context preview: the filtered ACTIVE layer is swapped into the
    // captured doc handle and the flattened result is shown, so blend modes
    // and the other layers stay visible while scrubbing.
    private let baseDoc: RasterDocument?
    private let layerIndex: Int
    private let baseLayer: RasterImage?
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
        self.baseDoc = document.doc
        self.layerIndex = document.activeLayerIndex
        self.baseLayer = document.doc?.layerImage(document.activeLayerIndex)
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
        grid.column(at: 0).width = 106

        let resetButton = StickerButton(
            title: "Reset", style: .secondary, target: self, action: #selector(resetClicked(_:)))
        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Adjust colors", content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton, leading: [resetButton]))
    }

    private func updateValueLabels() {
        brightnessValue.stringValue = String(format: "%.2f", brightnessSlider.doubleValue)
        contrastValue.stringValue = String(format: "%.2f", contrastSlider.doubleValue)
        saturationValue.stringValue = String(format: "%.2f", saturationSlider.doubleValue)
    }

    private func requestPreview() {
        guard let baseDoc = baseDoc, let baseLayer = baseLayer else { return }
        let brightness = brightnessSlider.doubleValue
        let contrast = contrastSlider.doubleValue
        let saturation = saturationSlider.doubleValue
        let idx = layerIndex
        renderer.request {
            guard
                let filtered = baseLayer.adjusted(
                    brightness: brightness, contrast: contrast, saturation: saturation),
                let previewDoc = baseDoc.withLayerPixels(idx, filtered)
            else { return nil }
            return previewDoc.flattened()?.makeCGImage()
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
        // Compose on the document's CURRENT active layer, not the captured
        // preview base, so any edit that slipped in while the sheet was open
        // survives.
        document.applyToActiveLayer("Adjust Colors") {
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
    private let baseDoc: RasterDocument?
    private let layerIndex: Int
    private let baseLayer: RasterImage?
    private let renderer = PreviewRenderer()

    private let sigmaSlider = NSSlider(
        value: 2, minValue: 0.5, maxValue: 25, target: nil, action: nil)
    private let sigmaValue = NSTextField(labelWithString: "2.0")

    init(document: ImageDocument, canvas: ImageCanvasView) {
        self.document = document
        self.canvas = canvas
        self.baseDoc = document.doc
        self.layerIndex = document.activeLayerIndex
        self.baseLayer = document.doc?.layerImage(document.activeLayerIndex)
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
        grid.column(at: 0).width = 106

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Gaussian blur", content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("one undo step")]))
    }

    private func requestPreview() {
        guard let baseDoc = baseDoc, let baseLayer = baseLayer else { return }
        let sigma = sigmaSlider.doubleValue
        let idx = layerIndex
        renderer.request {
            guard let filtered = baseLayer.blurred(sigma: sigma),
                  let previewDoc = baseDoc.withLayerPixels(idx, filtered)
            else { return nil }
            return previewDoc.flattened()?.makeCGImage()
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
        document.applyToActiveLayer("Gaussian Blur") { $0.blurred(sigma: sigma) }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}

// MARK: - FeatherSheetController

/// Select > Feather Selection…: Gaussian-softens the current selection's
/// coverage mask. Selections are not undoable and no pixels change, so
/// there is no live preview — the marquee and dimming update on Apply.
final class FeatherSheetController: NSViewController {
    private weak var canvas: ImageCanvasView?

    // Log-feel radius: the slider runs log10(0.5)…log10(250) so the
    // useful small radii get most of the travel.
    private let radiusSlider = NSSlider(
        value: log10(4.0), minValue: log10(0.5), maxValue: log10(250.0),
        target: nil, action: nil)
    private let radiusValue = NSTextField(labelWithString: "4.0 px")

    init(canvas: ImageCanvasView) {
        self.canvas = canvas
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FeatherSheetController does not support NSCoder")
    }

    override func loadView() {
        radiusSlider.isContinuous = true
        radiusSlider.target = self
        radiusSlider.action = #selector(sliderChanged(_:))
        radiusSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        radiusValue.font = DS.mono(12)
        radiusValue.textColor = DS.textMuted
        radiusValue.alignment = .right
        radiusValue.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let grid = NSGridView(views: [
            [fieldLabel("Radius:"), radiusSlider, radiusValue]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Feather selection",
            hint: "Softens the selection edge, so fills, gradients, and "
                + "strokes fade out across the radius.",
            content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("0.5 – 250 px")]))
    }

    private var radius: Double {
        pow(10, radiusSlider.doubleValue)
    }

    @objc private func sliderChanged(_ sender: Any?) {
        radiusValue.stringValue = String(format: "%.1f px", radius)
    }

    @objc private func applyClicked(_ sender: Any?) {
        let radius = radius
        dismiss(self)
        guard let canvas = canvas, let selection = canvas.selection else {
            NSSound.beep()
            return
        }
        // A feather that spreads all coverage to zero comes back nil and
        // deselects — the same all-empty rule as the combine modes.
        canvas.setSelection(selection.feathered(by: radius))
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}

// MARK: - SelectionMorphSheetController

/// Select > Grow/Shrink/Border/Smooth Selection…: FeatherSheetController's
/// numeric dialog, parameterized over the selection-morphology op Apply
/// runs. Selections are not undoable and no pixels change, so there is no
/// live preview — the marquee and dimming update on Apply.
final class SelectionMorphSheetController: NSViewController {
    private weak var canvas: ImageCanvasView?
    private let sheetTitle: String
    private let valueLabel: String
    private let hint: String
    private let transform: (CanvasSelection, Double) -> CanvasSelection?

    // The same log-feel travel as Feather: log10(0.5)…log10(250), so the
    // useful small values get most of the slider.
    private let valueSlider = NSSlider(
        value: log10(4.0), minValue: log10(0.5), maxValue: log10(250.0),
        target: nil, action: nil)
    private let valueField = NSTextField(labelWithString: "4.0 px")

    /// `label` is the parameter's row label ("Radius:", or Border's
    /// "Width:"); `transform` maps the current selection and the chosen
    /// value to the new selection (nil deselects).
    init(
        canvas: ImageCanvasView, title: String, label: String, hint: String,
        transform: @escaping (CanvasSelection, Double) -> CanvasSelection?
    ) {
        self.canvas = canvas
        self.sheetTitle = title
        self.valueLabel = label
        self.hint = hint
        self.transform = transform
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SelectionMorphSheetController does not support NSCoder")
    }

    override func loadView() {
        valueSlider.isContinuous = true
        valueSlider.target = self
        valueSlider.action = #selector(sliderChanged(_:))
        valueSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        valueField.font = DS.mono(12)
        valueField.textColor = DS.textMuted
        valueField.alignment = .right
        valueField.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let grid = NSGridView(views: [
            [fieldLabel(valueLabel), valueSlider, valueField]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: sheetTitle,
            hint: hint,
            content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("0.5 – 250 px")]))
    }

    private var value: Double {
        pow(10, valueSlider.doubleValue)
    }

    @objc private func sliderChanged(_ sender: Any?) {
        valueField.stringValue = String(format: "%.1f px", value)
    }

    @objc private func applyClicked(_ sender: Any?) {
        let value = value
        dismiss(self)
        guard let canvas = canvas, let selection = canvas.selection else {
            NSSound.beep()
            return
        }
        // An op that leaves no coverage (a shrink past the middle, a border
        // of an empty contour) comes back nil and deselects — the same
        // all-empty rule as Feather and the combine modes.
        canvas.setSelection(transform(selection, value))
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}

// MARK: - SliderSheetController

/// One slider row of a SliderSheetController: label, slider-space range, an
/// optional slider→value mapping (log-feel gamma), and a value formatter.
struct FilterSliderDescriptor {
    let label: String
    let sliderMin: Double
    let sliderMax: Double
    let sliderInitial: Double
    let isInteger: Bool
    let map: (Double) -> Double
    let format: (Double) -> String

    init(
        label: String, min: Double, max: Double, initial: Double,
        isInteger: Bool = false,
        map: @escaping (Double) -> Double = { $0 },
        format: @escaping (Double) -> String
    ) {
        self.label = label
        self.sliderMin = min
        self.sliderMax = max
        self.sliderInitial = initial
        self.isInteger = isInteger
        self.map = map
        self.format = format
    }
}

/// Generic live-preview filter sheet: N sliders and a compute closure that
/// filters the ACTIVE layer. The preview shows the edit in context (the
/// filtered layer swapped into the captured doc handle, flattened); Apply
/// routes through applyToActiveLayer as one undo step.
final class SliderSheetController: NSViewController {
    private let document: ImageDocument
    private weak var canvas: ImageCanvasView?
    private let sheetTitle: String
    private let actionName: String
    private let descriptors: [FilterSliderDescriptor]
    private let compute: (RasterImage, [Double]) -> RasterImage?
    private let willChange: ((Int, inout [Double]) -> Void)?
    private let baseDoc: RasterDocument?
    private let layerIndex: Int
    private let baseLayer: RasterImage?
    private let renderer = PreviewRenderer()
    private var sliders: [NSSlider] = []
    private var valueLabels: [NSTextField] = []
    private var didRequestInitialPreview = false

    /// `willChange` runs before a slider change is committed; it may adjust
    /// the OTHER sliders' (slider-space) values (Levels keeps black < white).
    init(
        document: ImageDocument, canvas: ImageCanvasView,
        title: String, actionName: String,
        sliders: [FilterSliderDescriptor],
        willChange: ((Int, inout [Double]) -> Void)? = nil,
        compute: @escaping (RasterImage, [Double]) -> RasterImage?
    ) {
        self.document = document
        self.canvas = canvas
        self.sheetTitle = title
        self.actionName = actionName
        self.descriptors = sliders
        self.willChange = willChange
        self.compute = compute
        self.baseDoc = document.doc
        self.layerIndex = document.activeLayerIndex
        self.baseLayer = document.doc?.layerImage(document.activeLayerIndex)
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SliderSheetController does not support NSCoder")
    }

    override func loadView() {
        var rows: [[NSView]] = []
        for descriptor in descriptors {
            let slider = NSSlider(
                value: descriptor.sliderInitial, minValue: descriptor.sliderMin,
                maxValue: descriptor.sliderMax, target: self, action: #selector(sliderChanged(_:)))
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true

            let label = NSTextField(
                labelWithString: descriptor.format(descriptor.map(descriptor.sliderInitial)))
            label.font = DS.mono(12)
            label.textColor = DS.textMuted
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true

            sliders.append(slider)
            valueLabels.append(label)
            rows.append([fieldLabel(descriptor.label), slider, label])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: sheetTitle, content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("one undo step")]))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Non-identity defaults (threshold, posterize, …) must preview
        // immediately so what the user sees is what Apply produces.
        guard !didRequestInitialPreview else { return }
        didRequestInitialPreview = true
        requestPreview()
    }

    private func mappedValues() -> [Double] {
        zip(sliders, descriptors).map { slider, descriptor in
            descriptor.map(slider.doubleValue)
        }
    }

    private func updateValueLabels() {
        for (index, descriptor) in descriptors.enumerated() {
            valueLabels[index].stringValue = descriptor.format(descriptor.map(sliders[index].doubleValue))
        }
    }

    private func requestPreview() {
        guard let baseDoc = baseDoc, let baseLayer = baseLayer else { return }
        let values = mappedValues()
        let idx = layerIndex
        let compute = compute
        renderer.request {
            guard let filtered = compute(baseLayer, values),
                  let previewDoc = baseDoc.withLayerPixels(idx, filtered)
            else { return nil }
            return previewDoc.flattened()?.makeCGImage()
        }
    }

    @objc private func sliderChanged(_ sender: Any?) {
        guard let slider = sender as? NSSlider,
              let index = sliders.firstIndex(where: { $0 === slider })
        else { return }
        if descriptors[index].isInteger {
            slider.doubleValue = slider.doubleValue.rounded()
        }
        if let willChange = willChange {
            var values = sliders.map { $0.doubleValue }
            willChange(index, &values)
            for (i, value) in values.enumerated() where sliders[i].doubleValue != value {
                sliders[i].doubleValue = value
            }
        }
        updateValueLabels()
        requestPreview()
    }

    @objc private func applyClicked(_ sender: Any?) {
        let values = mappedValues()
        let compute = compute
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        document.applyToActiveLayer(actionName) { compute($0, values) }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}

// MARK: - AdjustmentLayerSheetController

/// Live-preview sheet for a PARAMETERIZED adjustment-layer op, in either of
/// two modes: creating a NEW adjustment layer above the active one, or
/// re-editing an existing adjustment layer's meta. The slider rows reuse the
/// destructive dialogs' exact labels, ranges and mappings
/// (AdjustSheetController, the SliderSheetController factories) so the
/// destructive and non-destructive variants feel identical; only the commit
/// target differs. The preview chains the same PURE ops the commit will run,
/// on a doc handle captured at init — the document itself is untouched until
/// Apply (one undo step), so Cancel is nothing more than dropping the
/// preview: no undo registration, no edit count.
///
/// This class is also the dialog seam: `make(op:...)` is the one entry
/// point the editor calls, and it hands `.curves` to
/// CurvesAdjustmentSheetController (the curve editor under the same `Mode`
/// and completion contract) instead of building slider rows.
final class AdjustmentLayerSheetController: NSViewController {
    /// What Apply commits.
    enum Mode {
        /// Insert a new adjustment layer above the ACTIVE layer. Its mask
        /// comes from `selection` (the marquee's canvas-sized coverage,
        /// captured when the sheet opened and left up afterwards, exactly
        /// like Layer > Mask > From Selection) or is reveal-all when nil.
        case create(selection: [UInt8]?)
        /// Replace ONLY layer `layer`'s meta; `original` prefills the
        /// sliders, and an unchanged meta commits nothing.
        case edit(layer: Int, original: AdjustmentLayerPayload)
    }

    /// The op-specific pieces of a slider-built dialog.
    private struct Config {
        let sliders: [FilterSliderDescriptor]
        let willChange: ((Int, inout [Double]) -> Void)?
        /// Meta params from the sliders' MAPPED values (schema ranges are
        /// guaranteed by the slider ranges themselves).
        let params: ([Double]) -> [String: Any]
        /// SLIDER-space positions from a layer's params (edit-mode prefill),
        /// clamped defensively into the sliders' ranges.
        let sliderValues: (AdjustmentLayerPayload) -> [Double]
    }

    private static func config(for op: AdjustmentLayerOp) -> Config? {
        switch op {
        case .bcs:
            // AdjustSheetController's rows: three sliders, -1…1, 0.01 steps.
            let format = { String(format: "%.2f", $0) }
            return Config(
                sliders: [
                    FilterSliderDescriptor(
                        label: "Brightness:", min: -1, max: 1, initial: 0, format: format),
                    FilterSliderDescriptor(
                        label: "Contrast:", min: -1, max: 1, initial: 0, format: format),
                    FilterSliderDescriptor(
                        label: "Saturation:", min: -1, max: 1, initial: 0, format: format),
                ],
                willChange: nil,
                params: { ["brightness": $0[0], "contrast": $0[1], "saturation": $0[2]] },
                sliderValues: { payload in
                    ["brightness", "contrast", "saturation"].map {
                        payload.number($0, default: 0).clamped(-1, 1)
                    }
                })
        case .levels:
            // SliderSheetController.levels' rows, including the log-feel
            // gamma slider and the black < white constraint.
            let format = { String(format: "%.2f", $0) }
            return Config(
                sliders: [
                    FilterSliderDescriptor(
                        label: "Black:", min: 0, max: 0.99, initial: 0, format: format),
                    FilterSliderDescriptor(
                        label: "White:", min: 0.01, max: 1, initial: 1, format: format),
                    FilterSliderDescriptor(
                        label: "Gamma:", min: -1, max: 1, initial: 0,
                        map: { pow(10, $0) }, format: format),
                ],
                willChange: { changed, values in
                    // Keep black < white by pushing the OTHER slider along.
                    if changed == 0, values[1] <= values[0] {
                        values[1] = min(values[0] + 0.01, 1)
                    } else if changed == 1, values[0] >= values[1] {
                        values[0] = max(values[1] - 0.01, 0)
                    }
                },
                params: { ["black": $0[0], "white": $0[1], "gamma": $0[2]] },
                sliderValues: { payload in
                    var black = payload.number("black", default: 0).clamped(0, 0.99)
                    let white = payload.number("white", default: 1).clamped(0.01, 1)
                    if black >= white { black = max(white - 0.01, 0) }
                    let gamma = payload.number("gamma", default: 1).clamped(0.1, 10)
                    return [black, white, log10(gamma)]
                })
        case .hueRotate:
            return Config(
                sliders: [
                    FilterSliderDescriptor(
                        label: "Angle:", min: -180, max: 180, initial: 0,
                        format: { String(format: "%.0f°", $0) })
                ],
                willChange: nil,
                params: { ["degrees": $0[0]] },
                sliderValues: { payload in
                    // Any finite angle is legal in meta; show its wrap into
                    // the dialog's -180…180 range (rotation is mod 360).
                    var degrees = payload.number("degrees", default: 0)
                        .truncatingRemainder(dividingBy: 360)
                    if degrees > 180 { degrees -= 360 }
                    if degrees < -180 { degrees += 360 }
                    return [degrees]
                })
        case .threshold:
            return Config(
                sliders: [
                    FilterSliderDescriptor(
                        label: "Level:", min: 0, max: 1, initial: 0.5,
                        format: { String(format: "%.2f", $0) })
                ],
                willChange: nil,
                params: { ["level": $0[0]] },
                sliderValues: { [$0.number("level", default: 0.5).clamped(0, 1)] })
        case .posterize:
            return Config(
                sliders: [
                    FilterSliderDescriptor(
                        label: "Levels:", min: 2, max: 16, initial: 4, isInteger: true,
                        format: { String(Int($0.rounded())) })
                ],
                willChange: nil,
                params: { ["levels": Int($0[0].rounded())] },
                sliderValues: { [$0.number("levels", default: 4).rounded().clamped(2, 16)] })
        case .curves:
            // Curves has a dialog, but a bespoke one (the curve editor in
            // CurvesAdjustmentSheetController), not slider rows.
            return nil
        case .invert, .grayscale, .sepia:
            // Parameterless: created directly, nothing to dialog.
            return nil
        }
    }

    /// Whether `op` has a dialog to open — what enables Adjustment Options…
    /// (parameterless ops have none).
    static func opHasDialog(_ op: AdjustmentLayerOp) -> Bool {
        op == .curves || config(for: op) != nil
    }

    /// The one entry point the editor calls for both creation and re-edit;
    /// nil for an op without a dialog. `onCommitted` fires after a
    /// successful Apply with the created/edited layer's index (the editor
    /// selects it and refreshes).
    static func make(
        op: AdjustmentLayerOp, document: ImageDocument, canvas: ImageCanvasView,
        mode: Mode, onCommitted: ((Int) -> Void)? = nil
    ) -> NSViewController? {
        if op == .curves {
            let controller = CurvesAdjustmentSheetController(
                document: document, canvas: canvas, mode: mode)
            controller.onCommitted = onCommitted
            return controller
        }
        guard let config = config(for: op) else { return nil }
        let controller = AdjustmentLayerSheetController(
            op: op, config: config, document: document, canvas: canvas, mode: mode)
        controller.onCommitted = onCommitted
        return controller
    }

    private let document: ImageDocument
    private weak var canvas: ImageCanvasView?
    private let op: AdjustmentLayerOp
    private let config: Config
    private let mode: Mode
    // In-context preview base: the chained ops are applied to this captured
    // handle and the flattened result is shown, so masks, blend modes and
    // the other layers stay visible while scrubbing.
    private let baseDoc: RasterDocument?
    private let aboveIndex: Int
    private let renderer = PreviewRenderer()
    private var sliders: [NSSlider] = []
    private var valueLabels: [NSTextField] = []
    private var didRequestInitialPreview = false
    private var onCommitted: ((Int) -> Void)?

    private init(
        op: AdjustmentLayerOp, config: Config, document: ImageDocument,
        canvas: ImageCanvasView, mode: Mode
    ) {
        self.op = op
        self.config = config
        self.document = document
        self.canvas = canvas
        self.mode = mode
        self.baseDoc = document.doc
        self.aboveIndex = document.activeLayerIndex
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AdjustmentLayerSheetController does not support NSCoder")
    }

    override func loadView() {
        // Edit mode prefills from the layer's meta; create mode starts at
        // the descriptors' defaults, like the destructive dialogs.
        var initialValues = config.sliders.map { $0.sliderInitial }
        if case .edit(_, let original) = mode {
            let prefill = config.sliderValues(original)
            if prefill.count == initialValues.count { initialValues = prefill }
        }
        var rows: [[NSView]] = []
        for (index, descriptor) in config.sliders.enumerated() {
            let slider = NSSlider(
                value: initialValues[index], minValue: descriptor.sliderMin,
                maxValue: descriptor.sliderMax, target: self,
                action: #selector(sliderChanged(_:)))
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true

            let label = NSTextField(
                labelWithString: descriptor.format(descriptor.map(initialValues[index])))
            label.font = DS.mono(12)
            label.textColor = DS.textMuted
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true

            sliders.append(slider)
            valueLabels.append(label)
            rows.append([fieldLabel(descriptor.label), slider, label])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        let title: String
        if case .edit = mode {
            title = "\(op.displayName) options"
        } else {
            title = "New \(op.displayName) layer"
        }
        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: title, content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("one undo step")]))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // A newly inserted layer with non-identity defaults (threshold,
        // posterize) must preview immediately so what the user sees is what
        // Apply produces.
        guard !didRequestInitialPreview else { return }
        didRequestInitialPreview = true
        requestPreview()
    }

    private func mappedValues() -> [Double] {
        zip(sliders, config.sliders).map { slider, descriptor in
            descriptor.map(slider.doubleValue)
        }
    }

    private func updateValueLabels() {
        for (index, descriptor) in config.sliders.enumerated() {
            valueLabels[index].stringValue =
                descriptor.format(descriptor.map(sliders[index].doubleValue))
        }
    }

    private func metaJSON(_ values: [Double]) -> String? {
        AdjustmentLayerPayload(op: op, params: config.params(values)).json()
    }

    /// Previews the SAME chained pure ops Apply will commit, applied to the
    /// captured base and flattened (self stays off the render queue; only
    /// captured values cross).
    private func requestPreview() {
        guard let baseDoc = baseDoc, let meta = metaJSON(mappedValues()) else { return }
        let mode = mode
        let above = aboveIndex
        let name = op.displayName
        renderer.request {
            let previewDoc: RasterDocument?
            switch mode {
            case .create(let selection):
                previewDoc = baseDoc.addingAdjustmentLayer(
                    above: above, name: name, meta: meta, selection: selection)
            case .edit(let idx, _):
                previewDoc = baseDoc.withLayerMeta(idx, meta)
            }
            return previewDoc?.flattened()?.makeCGImage()
        }
    }

    @objc private func sliderChanged(_ sender: Any?) {
        guard let slider = sender as? NSSlider,
              let index = sliders.firstIndex(where: { $0 === slider })
        else { return }
        if config.sliders[index].isInteger {
            slider.doubleValue = slider.doubleValue.rounded()
        }
        if let willChange = config.willChange {
            var values = sliders.map { $0.doubleValue }
            willChange(index, &values)
            for (i, value) in values.enumerated() where sliders[i].doubleValue != value {
                sliders[i].doubleValue = value
            }
        }
        updateValueLabels()
        requestPreview()
    }

    @objc private func applyClicked(_ sender: Any?) {
        let values = mappedValues()
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        guard let meta = metaJSON(values) else {
            NSSound.beep()
            return
        }
        switch mode {
        case .create(let selection):
            // Compose on the document's CURRENT doc and active layer, not
            // the captured preview base, so any edit that slipped in while
            // the sheet was open (an agent's) survives.
            let below = document.activeLayerIndex
            let name = op.displayName
            let before = document.doc
            document.applyEdit("New \(name) Layer") {
                $0.addingAdjustmentLayer(
                    above: below, name: name, meta: meta, selection: selection)
            }
            guard document.doc !== before, let doc = document.doc else { return }
            onCommitted?(min(below + 1, doc.layerCount - 1))
        case .edit(let idx, let original):
            // Closing the dialog with unchanged values must not register an
            // undo step or dirty the file (sorted-key encoding makes the
            // comparison byte-stable).
            guard meta != original.json() else { return }
            document.applyEdit("Edit \(op.displayName) Layer") { doc in
                // The layer must still BE an adjustment layer (only an agent
                // edit can move the stack under an open sheet).
                guard doc.layerIsAdjustment(idx) else { return nil }
                return doc.withLayerMeta(idx, meta)
            }
            onCommitted?(idx)
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}

extension Double {
    fileprivate func clamped(_ low: Double, _ high: Double) -> Double {
        Swift.min(Swift.max(self, low), high)
    }
}

// MARK: - CurvesAdjustmentSheetController

/// The `.curves` branch of the adjustment-layer dialog seam: identical
/// lifecycle to AdjustmentLayerSheetController — same `Mode`, same
/// captured-handle live preview of the exact chained pure ops Apply will
/// commit, Apply = one undo step through applyEdit, Cancel = drop the
/// preview — but the content is a channel popup + CurveEditorView instead
/// of slider rows. Per-channel point lists live here; the view only ever
/// shows (and edits) the current channel's.
final class CurvesAdjustmentSheetController: NSViewController {
    private let document: ImageDocument
    private weak var canvas: ImageCanvasView?
    private let mode: AdjustmentLayerSheetController.Mode
    // In-context preview base: the chained ops are applied to this captured
    // handle and the flattened result is shown, so masks, blend modes and
    // the other layers stay visible while editing.
    private let baseDoc: RasterDocument?
    private let aboveIndex: Int
    private let renderer = PreviewRenderer()
    var onCommitted: ((Int) -> Void)?

    private var channelPoints: [CurveChannel: [CurvePoint]] = [:]
    private var channel: CurveChannel = .rgb
    private let channelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let curveView = CurveEditorView()
    private let readoutLabel = NSTextField(labelWithString: "")
    private var didRequestInitialPreview = false

    init(
        document: ImageDocument, canvas: ImageCanvasView,
        mode: AdjustmentLayerSheetController.Mode
    ) {
        self.document = document
        self.canvas = canvas
        self.mode = mode
        self.baseDoc = document.doc
        self.aboveIndex = document.activeLayerIndex
        // Edit mode prefills every channel from the layer's meta (missing
        // channels show identity); create mode starts all-identity.
        for ch in CurveChannel.allCases {
            if case .edit(_, let original) = mode {
                channelPoints[ch] = CurvesMeta.points(of: ch, in: original)
            } else {
                channelPoints[ch] = CurvePoint.identity
            }
        }
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CurvesAdjustmentSheetController does not support NSCoder")
    }

    override func loadView() {
        channelPopup.addItems(withTitles: CurveChannel.allCases.map { $0.displayName })
        channelPopup.font = DS.sans(13)
        channelPopup.target = self
        channelPopup.action = #selector(channelChanged(_:))

        let channelRow = NSStackView(views: [fieldLabel("Channel:"), channelPopup])
        channelRow.orientation = .horizontal
        channelRow.alignment = .centerY
        channelRow.spacing = 8

        curveView.points = channelPoints[channel] ?? CurvePoint.identity
        curveView.curveColor = channel.strokeColor
        curveView.onPointsChanged = { [weak self] points in
            guard let self = self else { return }
            self.channelPoints[self.channel] = points
            self.requestPreview()
        }
        curveView.onDragReadout = { [weak self] readout in
            self?.readoutLabel.stringValue = readout ?? ""
        }
        // Pin the square explicitly so stack stretching can never skew the
        // plot's value mapping.
        let side = curveView.intrinsicContentSize.width
        NSLayoutConstraint.activate([
            curveView.widthAnchor.constraint(equalToConstant: side),
            curveView.heightAnchor.constraint(equalToConstant: side),
        ])

        // Live "in → out" readout during drags, in the options bar's numeric
        // style (monospaced digits, small).
        readoutLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        readoutLabel.textColor = DS.textMuted

        let resetButton = StickerButton(
            title: "Reset", style: .secondary, target: self, action: #selector(resetClicked(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        let underRow = NSStackView(views: [readoutLabel, spacer, resetButton])
        underRow.orientation = .horizontal
        underRow.alignment = .centerY
        underRow.spacing = 8

        let content = NSStackView(views: [channelRow, curveView, underRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        underRow.widthAnchor.constraint(equalTo: curveView.widthAnchor).isActive = true

        let title: String
        if case .edit = mode {
            title = "\(AdjustmentLayerOp.curves.displayName) options"
        } else {
            title = "New \(AdjustmentLayerOp.curves.displayName) layer"
        }
        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: title,
            hint: "Click the curve to add a point (Reset clears the current "
                + "channel); drag a point off the plot to remove it.",
            content: content,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("one undo step")]))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Same pattern as the slider sheets: preview immediately so what the
        // user sees is what Apply produces.
        guard !didRequestInitialPreview else { return }
        didRequestInitialPreview = true
        requestPreview()
    }

    /// Meta from the current point lists: only non-identity channels are
    /// included (missing channel = identity in the schema); all-identity is
    /// a valid curves op with empty params.
    private func metaJSON() -> String? {
        AdjustmentLayerPayload(op: .curves, params: CurvesMeta.params(channelPoints)).json()
    }

    private func requestPreview() {
        guard let baseDoc = baseDoc, let meta = metaJSON() else { return }
        let mode = mode
        let above = aboveIndex
        let name = AdjustmentLayerOp.curves.displayName
        renderer.request {
            let previewDoc: RasterDocument?
            switch mode {
            case .create(let selection):
                previewDoc = baseDoc.addingAdjustmentLayer(
                    above: above, name: name, meta: meta, selection: selection)
            case .edit(let idx, _):
                previewDoc = baseDoc.withLayerMeta(idx, meta)
            }
            return previewDoc?.flattened()?.makeCGImage()
        }
    }

    @objc private func channelChanged(_ sender: Any?) {
        let index = channelPopup.indexOfSelectedItem
        guard index >= 0, index < CurveChannel.allCases.count else { return }
        channel = CurveChannel.allCases[index]
        curveView.points = channelPoints[channel] ?? CurvePoint.identity
        curveView.curveColor = channel.strokeColor
        readoutLabel.stringValue = ""
        // Switching channels changes nothing in the meta — no new preview.
    }

    /// Resets the CURRENT channel to identity; the others keep their points.
    @objc private func resetClicked(_ sender: Any?) {
        channelPoints[channel] = CurvePoint.identity
        curveView.points = CurvePoint.identity
        requestPreview()
    }

    @objc private func applyClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        guard let meta = metaJSON() else {
            NSSound.beep()
            return
        }
        let name = AdjustmentLayerOp.curves.displayName
        switch mode {
        case .create(let selection):
            // Compose on the document's CURRENT doc and active layer, not
            // the captured preview base, so any edit that slipped in while
            // the sheet was open (an agent's) survives.
            let below = document.activeLayerIndex
            let before = document.doc
            document.applyEdit("New \(name) Layer") {
                $0.addingAdjustmentLayer(
                    above: below, name: name, meta: meta, selection: selection)
            }
            guard document.doc !== before, let doc = document.doc else { return }
            onCommitted?(min(below + 1, doc.layerCount - 1))
        case .edit(let idx, let original):
            // Closing the dialog with unchanged values must not register an
            // undo step or dirty the file (sorted-key encoding makes the
            // comparison byte-stable for metas this app wrote).
            guard meta != original.json() else { return }
            document.applyEdit("Edit \(name) Layer") { doc in
                // The layer must still BE an adjustment layer (only an agent
                // edit can move the stack under an open sheet).
                guard doc.layerIsAdjustment(idx) else { return nil }
                return doc.withLayerMeta(idx, meta)
            }
            onCommitted?(idx)
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}

// MARK: - Filter sheet factories

extension SliderSheetController {
    static func hueRotate(document: ImageDocument, canvas: ImageCanvasView) -> SliderSheetController {
        SliderSheetController(
            document: document, canvas: canvas,
            title: "Hue Rotate", actionName: "Hue Rotate",
            sliders: [
                FilterSliderDescriptor(
                    label: "Angle:", min: -180, max: 180, initial: 0,
                    format: { String(format: "%.0f°", $0) })
            ],
            compute: { image, values in
                image.hueRotated(degrees: values[0])
            })
    }

    static func levels(document: ImageDocument, canvas: ImageCanvasView) -> SliderSheetController {
        SliderSheetController(
            document: document, canvas: canvas,
            title: "Levels", actionName: "Levels",
            sliders: [
                FilterSliderDescriptor(
                    label: "Black:", min: 0, max: 0.99, initial: 0,
                    format: { String(format: "%.2f", $0) }),
                FilterSliderDescriptor(
                    label: "White:", min: 0.01, max: 1, initial: 1,
                    format: { String(format: "%.2f", $0) }),
                // Log-feel gamma: the slider runs -1…1 and maps to 10^x, so
                // 0.1, 1, and 10 sit at the left edge, center, and right edge.
                FilterSliderDescriptor(
                    label: "Gamma:", min: -1, max: 1, initial: 0,
                    map: { pow(10, $0) },
                    format: { String(format: "%.2f", $0) }),
            ],
            willChange: { changed, values in
                // Keep black < white by pushing the OTHER slider along.
                if changed == 0, values[1] <= values[0] {
                    values[1] = min(values[0] + 0.01, 1)
                } else if changed == 1, values[0] >= values[1] {
                    values[0] = max(values[1] - 0.01, 0)
                }
            },
            compute: { image, values in
                image.levels(black: values[0], white: values[1], gamma: values[2])
            })
    }

    static func threshold(document: ImageDocument, canvas: ImageCanvasView) -> SliderSheetController {
        SliderSheetController(
            document: document, canvas: canvas,
            title: "Threshold", actionName: "Threshold",
            sliders: [
                FilterSliderDescriptor(
                    label: "Level:", min: 0, max: 1, initial: 0.5,
                    format: { String(format: "%.2f", $0) })
            ],
            compute: { image, values in
                image.thresholded(level: values[0])
            })
    }

    static func posterize(document: ImageDocument, canvas: ImageCanvasView) -> SliderSheetController {
        SliderSheetController(
            document: document, canvas: canvas,
            title: "Posterize", actionName: "Posterize",
            sliders: [
                FilterSliderDescriptor(
                    label: "Levels:", min: 2, max: 16, initial: 4, isInteger: true,
                    format: { String(Int($0.rounded())) })
            ],
            compute: { image, values in
                image.posterized(levels: Int(values[0].rounded()))
            })
    }

    static func pixelate(document: ImageDocument, canvas: ImageCanvasView) -> SliderSheetController {
        SliderSheetController(
            document: document, canvas: canvas,
            title: "Pixelate", actionName: "Pixelate",
            sliders: [
                FilterSliderDescriptor(
                    label: "Block size:", min: 2, max: 64, initial: 8, isInteger: true,
                    format: { String(Int($0.rounded())) })
            ],
            compute: { image, values in
                image.pixelated(block: Int(values[0].rounded()))
            })
    }

    static func addNoise(document: ImageDocument, canvas: ImageCanvasView) -> SliderSheetController {
        // One seed per sheet open, shared by preview and Apply, so the
        // committed noise is exactly what was previewed.
        let seed = UInt64.random(in: UInt64.min ... UInt64.max)
        return SliderSheetController(
            document: document, canvas: canvas,
            title: "Add Noise", actionName: "Add Noise",
            sliders: [
                FilterSliderDescriptor(
                    label: "Amount:", min: 0.02, max: 1, initial: 0.1,
                    format: { String(format: "%.2f", $0) })
            ],
            compute: { image, values in
                image.noised(amount: values[0], seed: seed)
            })
    }
}
