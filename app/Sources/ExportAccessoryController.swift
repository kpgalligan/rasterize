import AppKit

/// Accessory view for the export save panel: format popup, a JPEG-only
/// quality slider, and the two colour/metadata checkboxes.
///
/// Every per-format answer the checkboxes need — greyed or live, and the
/// tooltip either way — comes from `ExportCapabilities`, which asks the
/// core. This file decides layout and nothing about what a PNG can hold.
final class ExportAccessoryController: NSViewController {
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(
        value: 90, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "Quality:")
    private let qualityValueLabel = NSTextField(labelWithString: "90")
    private let profileCheckbox = NSButton(
        checkboxWithTitle: "Embed colour profile", target: nil, action: nil)
    private let metadataCheckbox = NSButton(
        checkboxWithTitle: "Strip metadata", target: nil, action: nil)

    var onFormatChange: ((ExportFormat) -> Void)?

    private var format: ExportFormat = .png
    private var qualityValue: Int = 90
    private var embed = true
    private var strip = false

    /// Embed the document's ICC profile in the exported file. Default on:
    /// an untagged export is the bug colour management exists to prevent.
    /// The export path honours it, and a format that cannot carry a profile
    /// ignores it — the checkbox greys out and says why.
    var embedProfile: Bool {
        get { embed }
        set {
            embed = newValue
            if isViewLoaded { syncControls() }
        }
    }

    /// Drop the document's EXIF / XMP / IPTC packets. Default off, so a
    /// photograph keeps its capture data (with the orientation reset).
    var stripMetadata: Bool {
        get { strip }
        set {
            strip = newValue
            if isViewLoaded { syncControls() }
        }
    }

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
        formatPopup.font = DS.sans(13)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))

        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged(_:))
        qualitySlider.widthAnchor.constraint(equalToConstant: 150).isActive = true

        qualityLabel.font = DS.sans(13)
        qualityValueLabel.font = DS.mono(12)
        qualityValueLabel.alignment = .right
        qualityValueLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        for box in [profileCheckbox, metadataCheckbox] {
            box.font = DS.sans(13)
            box.target = self
            box.action = #selector(optionChanged(_:))
        }

        let formatLabel = NSTextField(labelWithString: "Format:")
        formatLabel.font = DS.sans(13)
        // The checkboxes go in the control column, so the popup, the slider
        // and both boxes share one left edge; column 0 is the trailing
        // label column and a checkbox carries its own title instead.
        let grid = NSGridView(views: [
            [formatLabel, formatPopup, NSGridCell.emptyContentView],
            [qualityLabel, qualitySlider, qualityValueLabel],
            [NSGridCell.emptyContentView, profileCheckbox, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, metadataCheckbox, NSGridCell.emptyContentView],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        // The frame is the panel's opening size; the grid's top and bottom
        // constraints set the height that is actually used. 84 → 132 leaves
        // room for the two checkbox rows and the 8pt of spacing above each.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 132))
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
        syncOption(profileCheckbox, .colorProfile, on: embed)
        syncOption(metadataCheckbox, .metadata, on: strip)
    }

    /// One checkbox against the chosen format: its state, whether it has
    /// anything to decide, and the tooltip that explains either case.
    ///
    /// A disabled `NSButton` greys its own title, so unlike the quality
    /// row's plain labels there is nothing here to recolour by hand.
    ///
    /// A greyed box keeps showing the standing preference rather than
    /// flipping to the outcome the format forces: the preference has to
    /// survive a trip through BMP and back, and a checkbox that moved on
    /// its own would read as an edit the user made.
    private func syncOption(_ box: NSButton, _ option: ExportCapabilities.Option, on: Bool) {
        box.state = on ? .on : .off
        let reason = ExportCapabilities.disabledReason(format, for: option)
        box.isEnabled = reason == nil
        box.toolTip = reason ?? ExportCapabilities.carriedNote(format, for: option)
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

    /// Both checkboxes report here: neither changes what the other or the
    /// format popup shows, so there is nothing to re-sync.
    @objc private func optionChanged(_ sender: Any?) {
        embed = profileCheckbox.state == .on
        strip = metadataCheckbox.state == .on
    }
}
