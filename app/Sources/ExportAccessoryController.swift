import AppKit

/// Accessory view for the export save panel: format popup plus a JPEG-only
/// quality slider.
final class ExportAccessoryController: NSViewController {
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(
        value: 90, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "Quality:")
    private let qualityValueLabel = NSTextField(labelWithString: "90")

    var onFormatChange: ((ExportFormat) -> Void)?

    private var format: ExportFormat = .png
    private var qualityValue: Int = 90

    var selectedFormat: ExportFormat {
        get { format }
        set {
            format = newValue
            if isViewLoaded { syncControls() }
        }
    }

    var quality: Int {
        get { qualityValue }
        set {
            qualityValue = min(max(newValue, 10), 100)
            if isViewLoaded { syncControls() }
        }
    }

    override func loadView() {
        formatPopup.addItems(withTitles: ExportFormat.allCases.map { $0.displayName })
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))

        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged(_:))
        qualitySlider.widthAnchor.constraint(equalToConstant: 150).isActive = true

        qualityValueLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        qualityValueLabel.alignment = .right
        qualityValueLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Format:"), formatPopup, NSGridCell.emptyContentView],
            [qualityLabel, qualitySlider, qualityValueLabel],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 84))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        view = container
        syncControls()
    }

    private func syncControls() {
        let all = ExportFormat.allCases
        if let index = all.firstIndex(of: format) {
            formatPopup.selectItem(at: index)
        }
        qualitySlider.integerValue = qualityValue
        qualityValueLabel.stringValue = "\(qualityValue)"
        let jpegSelected = format == .jpeg
        qualitySlider.isEnabled = jpegSelected
        qualityLabel.textColor = jpegSelected ? .labelColor : .disabledControlTextColor
        qualityValueLabel.textColor = jpegSelected ? .labelColor : .disabledControlTextColor
    }

    @objc private func formatChanged(_ sender: Any?) {
        let all = ExportFormat.allCases
        let index = formatPopup.indexOfSelectedItem
        guard index >= 0, index < all.count else { return }
        format = all[index]
        syncControls()
        onFormatChange?(format)
    }

    @objc private func qualityChanged(_ sender: Any?) {
        qualityValue = qualitySlider.integerValue
        qualityValueLabel.stringValue = "\(qualityValue)"
    }
}
