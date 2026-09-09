import AppKit

/// Image > Channels > Channel Options… (also the channels row menu): the
/// name and the rubylith a channel is drawn in. The rubylith is DISPLAY
/// state — it never changes a byte of the channel's coverage — so the only
/// thing this sheet needs to preview is itself.
///
/// Apply chains the rename and the overlay change inside ONE transform
/// closure, so the whole dialog is one undo step.
final class ChannelOptionsSheetController: NSViewController {
    private let document: ImageDocument
    private let index: Int

    private let nameField = NSTextField(string: "")
    private let maskedRadio = NSButton(
        radioButtonWithTitle: "Masked Areas", target: nil, action: nil)
    private let selectedRadio = NSButton(
        radioButtonWithTitle: "Selected Areas", target: nil, action: nil)
    private let colorWell = NSColorWell(frame: .zero)
    private let opacitySlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let opacityField = NSTextField(string: "50")

    /// nil when the index is gone by the time the sheet opens; the caller
    /// beeps rather than presenting an empty dialog.
    init?(document: ImageDocument, channel index: Int) {
        guard let info = document.doc?.channelInfo(index) else { return nil }
        self.document = document
        self.index = index
        super.init(nibName: nil, bundle: nil)
        nameField.stringValue = info.name
        colorWell.color = NSColor(
            srgbRed: CGFloat(info.red) / 255, green: CGFloat(info.green) / 255,
            blue: CGFloat(info.blue) / 255, alpha: 1)
        opacitySlider.doubleValue = (info.opacity * 100).rounded()
        opacityField.stringValue = String(Int(opacitySlider.doubleValue))
        maskedRadio.state = info.colorIndicatesSelected ? .off : .on
        selectedRadio.state = info.colorIndicatesSelected ? .on : .off
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChannelOptionsSheetController does not support NSCoder")
    }

    override func loadView() {
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        DSField.style(nameField)

        for radio in [maskedRadio, selectedRadio] {
            radio.target = self
            radio.action = #selector(polarityChanged(_:))
            radio.font = DS.sans(13)
        }
        let polarity = NSStackView(views: [maskedRadio, selectedRadio])
        polarity.orientation = .horizontal
        polarity.spacing = 14

        colorWell.widthAnchor.constraint(equalToConstant: 54).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true

        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(sliderChanged(_:))
        opacitySlider.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 100
        opacityField.formatter = formatter
        opacityField.target = self
        opacityField.action = #selector(fieldChanged(_:))
        opacityField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        DSField.style(opacityField)

        let opacityRow = NSStackView(views: [opacitySlider, opacityField])
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 10

        let grid = NSGridView(views: [
            [fieldLabel("Name:"), nameField],
            [fieldLabel("Color Indicates:"), polarity],
            [fieldLabel("Color:"), colorWell],
            [fieldLabel("Opacity:"), opacityRow],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Channel Options",
            hint: "The rubylith a channel is drawn in over the image. Display only — it is "
                + "never part of the picture. Masked Areas (the default) washes where the "
                + "channel is black, exactly like Quick Mask.",
            content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("one undo step")]))
    }

    @objc private func polarityChanged(_ sender: Any?) {
        guard let sender = sender as? NSButton else { return }
        maskedRadio.state = sender === maskedRadio ? .on : .off
        selectedRadio.state = sender === selectedRadio ? .on : .off
    }

    @objc private func sliderChanged(_ sender: Any?) {
        opacityField.stringValue = String(Int(opacitySlider.doubleValue.rounded()))
    }

    @objc private func fieldChanged(_ sender: Any?) {
        opacitySlider.doubleValue = min(max(Double(opacityField.integerValue), 0), 100)
        opacityField.stringValue = String(Int(opacitySlider.doubleValue))
    }

    @objc private func applyClicked(_ sender: Any?) {
        // Trimmed before the emptiness test, the panel's inline field's rule:
        // a whitespace-only name draws as a blank row and can then only be
        // addressed by index, which is exactly what the agent's
        // `set_channel_options` declines to set.
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = colorWell.color.usingColorSpace(.sRGB) ?? .red
        // The picker can hand back a Display P3 colour whose sRGB
        // components fall outside 0…1; clamping before the byte conversion
        // is what keeps that from trapping (LayerStyleColor.hex's rule).
        let byte: (CGFloat) -> UInt8 = { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        let red = byte(color.redComponent)
        let green = byte(color.greenComponent)
        let blue = byte(color.blueComponent)
        let opacity = min(max(opacitySlider.doubleValue, 0), 100) / 100
        let indicatesSelected = selectedRadio.state == .on
        let index = self.index
        dismiss(self)
        // Both core calls chain inside ONE transform: either half may
        // legitimately refuse (nothing changed), so the second falls back to
        // the first's result rather than to nil.
        // Addressed by the channel's CURRENT name — what the replay document
        // still calls it — with the new name in `name`, exactly as a layer
        // rename records.
        let record: [ActionStep] =
            (document.doc?.channelInfo(index)?.name).map { current in
                var arguments: [String: Any] = [
                    "channel": current,
                    "overlay_color": RasterImage.hexString(
                        (r: red, g: green, b: blue, a: 255)),
                    "overlay_opacity": (opacity * 100).rounded() / 100,
                    "color_indicates": indicatesSelected ? "selected" : "masked",
                ]
                if !name.isEmpty { arguments["name"] = name }
                return .channelCommand(
                    "set_channel_options", arguments, note: "Channels ▸ Channel Options…")
            } ?? .unrecorded("Channel Options")
        document.applyEdit("Channel Options", record: record) { doc in
            let renamed = name.isEmpty ? doc : (doc.renamingChannel(index, name) ?? doc)
            let recoloured = renamed.settingChannelOverlay(
                index, red: red, green: green, blue: blue, opacity: opacity,
                indicatesSelected: indicatesSelected)
            let updated = recoloured ?? renamed
            // A dialog that changed nothing must not mint an undo step.
            return updated === doc ? nil : updated
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}
