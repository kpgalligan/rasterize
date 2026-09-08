import AppKit

/// Image > Image Size…: the pixel dimensions, and the print resolution and
/// print size beside them.
///
/// The resize dialog moved out of `Sheets.swift` under the name the feature
/// actually has, so there is exactly one Image Size dialog in the tree. It
/// still does what it always did — width, height, a locked aspect ratio and
/// a resampling filter, guarded by the 100 MP cap and the channel budget —
/// with Photoshop's Resample switch over the top:
///
/// - **Resample off**: the pixel count is fixed. The pixel fields, the
///   aspect lock and the filter are disabled, and the Resolution and Print
///   size rows drive each other through the pixels that do not move. The
///   commit is a resolution edit alone: no geometry op, no resampling, one
///   undo step.
/// - **Resample on**: the pixel dimensions and the resolution are
///   independent. Editing the pixels or the print size moves pixels;
///   editing the resolution moves only the print size. Both changes chain
///   into ONE `applyEdit` closure, so the dialog is still one undo step.
///
/// All three quantities live in a single `PrintSize` (`current`), the one
/// place `print size = pixels / ppi` is written down, so the fields cannot
/// disagree with each other or with what File > Print puts on paper.
final class ImageSizeSheetController: NSViewController, NSTextFieldDelegate {
    private let document: ImageDocument
    private let originalWidth: Int
    private let originalHeight: Int
    /// The document as the sheet opened: what every "did anything actually
    /// change?" test is against.
    private let original: PrintSize
    /// The pending value the fields are views onto.
    private var current: PrintSize

    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")
    private let resolutionField = NSTextField(string: "")
    private let printWidthField = NSTextField(string: "")
    private let printHeightField = NSTextField(string: "")
    private let resolutionFormatter = NumberFormatter()
    private let lockCheckbox = NSButton(
        checkboxWithTitle: "Lock aspect ratio", target: nil, action: nil)
    private let resampleCheckbox = NSButton(
        checkboxWithTitle: "Resample", target: nil, action: nil)
    private let resolutionUnitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lengthUnitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private static let filters: [(title: String, value: RzResizeFilter)] = [
        ("Nearest", RZ_FILTER_NEAREST),
        ("Bilinear", RZ_FILTER_BILINEAR),
        ("Catmull-Rom", RZ_FILTER_CATMULL_ROM),
        ("Lanczos3", RZ_FILTER_LANCZOS3),
    ]

    init(document: ImageDocument) {
        self.document = document
        let width = document.doc?.width ?? 1
        let height = document.doc?.height ?? 1
        let ppi = document.doc?.resolution ?? (x: 72, y: 72)
        self.originalWidth = width
        self.originalHeight = height
        self.original = PrintSize(pixels: (width, height), ppi: ppi)
        self.current = self.original
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ImageSizeSheetController does not support NSCoder")
    }

    /// The unit each popup is showing. Read from the popup rather than
    /// stored, so there is no second copy to keep in step with it.
    private var resolutionUnit: PrintUnit {
        PrintUnit(rawValue: resolutionUnitPopup.indexOfSelectedItem) ?? .inches
    }

    private var lengthUnit: PrintUnit {
        PrintUnit(rawValue: lengthUnitPopup.indexOfSelectedItem) ?? .inches
    }

    override func loadView() {
        for field in [widthField, heightField] {
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.allowsFloats = false
            formatter.minimum = 1
            formatter.maximum = NSNumber(value: PrintSize.maxPixelsPerAxis)
            field.formatter = formatter
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            DSField.style(field)
        }
        lockCheckbox.state = .on
        resampleCheckbox.state = .on
        resampleCheckbox.target = self
        resampleCheckbox.action = #selector(resampleChanged(_:))

        // A resolution is a Double, so unlike the pixel fields it takes
        // fractions; three decimals is the finest a ppi field is ever read
        // at and stays well inside the core's four-decimal quantization.
        resolutionFormatter.numberStyle = .decimal
        resolutionFormatter.allowsFloats = true
        resolutionFormatter.maximumFractionDigits = 3
        resolutionField.formatter = resolutionFormatter
        resolutionField.delegate = self
        resolutionField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        DSField.style(resolutionField)

        for field in [printWidthField, printHeightField] {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.allowsFloats = true
            formatter.maximumFractionDigits = 3
            // A print size has no bound of its own: what actually limits it
            // is the resolution range, which `PrintSize` clamps into. The
            // floor only keeps a zero out of a divisor.
            formatter.minimum = 0.001
            field.formatter = formatter
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
            DSField.style(field)
        }

        for unit in PrintUnit.allCases {
            resolutionUnitPopup.addItem(withTitle: unit.resolutionTitle)
            lengthUnitPopup.addItem(withTitle: unit.lengthTitle)
        }
        for popup in [resolutionUnitPopup, lengthUnitPopup] {
            popup.selectItem(at: PrintUnit.inches.rawValue)
            popup.font = DS.sans(13)
            popup.target = self
            popup.action = #selector(unitChanged(_:))
        }

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
            [fieldLabel("Resolution:"), row([resolutionField, resolutionUnitPopup])],
            [
                fieldLabel("Print size:"),
                row([printWidthField, timesLabel(), printHeightField, lengthUnitPopup]),
            ],
            [NSGridCell.emptyContentView, resampleCheckbox],
            [fieldLabel("Filter:"), filterPopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        syncResolutionBounds()
        syncEnabled()
        syncFields(except: nil)

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Image size",
            hint: "Resample changes the pixel count. With it off the pixels are left alone "
                + "and only the print resolution and the print size change.",
            content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("max 100 MP")]))
    }

    /// One grid cell holding several controls on a line — the 106pt label
    /// column and the 420pt card leave 258pt for it.
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func timesLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "×")
        label.font = DS.sans(13)
        label.textColor = DS.textMuted
        return label
    }

    // MARK: - Keeping the fields and `current` in step

    /// Resample off means the pixel count is fixed, so every control that
    /// exists to change it is disabled — greyed with the app's
    /// `isEnabled` + muted `textColor` convention.
    private func syncEnabled() {
        let resampling = resampleCheckbox.state == .on
        for field in [widthField, heightField] {
            field.isEnabled = resampling
            field.textColor = resampling ? DS.textStrong : DS.textMuted
        }
        lockCheckbox.isEnabled = resampling
        filterPopup.isEnabled = resampling
    }

    /// The resolution field's bounds are the core's ppi range expressed in
    /// whichever unit the popup shows, so 30000 ppi reads as 11811.024
    /// pixels/cm rather than being refused there.
    private func syncResolutionBounds() {
        let perInch = resolutionUnit.perInch
        resolutionFormatter.minimum = NSNumber(value: PrintSize.ppiRange.lowerBound / perInch)
        resolutionFormatter.maximum = NSNumber(value: PrintSize.ppiRange.upperBound / perInch)
    }

    /// Rewrites every field except `editing` from `current`, so a value the
    /// user is part-way through typing is never yanked out from under the
    /// cursor. Pass nil once editing ends to snap the typed field to what
    /// the value actually became — a resolution past 30000 ppi clamps, and
    /// the field has to say so.
    private func syncFields(except editing: NSTextField?) {
        if widthField !== editing { widthField.integerValue = current.pixels.width }
        if heightField !== editing { heightField.integerValue = current.pixels.height }
        if resolutionField !== editing {
            resolutionField.doubleValue = current.resolution(in: resolutionUnit).x
        }
        let printed = current.size(in: lengthUnit)
        if printWidthField !== editing { printWidthField.doubleValue = printed.width }
        if printHeightField !== editing { printHeightField.doubleValue = printed.height }
    }

    /// With Resample and Lock aspect ratio both on, a change to one pixel
    /// dimension carries the other with it — against the document's
    /// ORIGINAL aspect, so a sequence of edits cannot drift.
    private func lockingAspect(_ size: PrintSize, drivenByWidth: Bool) -> PrintSize {
        guard lockCheckbox.state == .on, originalWidth > 0, originalHeight > 0 else { return size }
        let aspect = Double(originalHeight) / Double(originalWidth)
        if drivenByWidth {
            return size.settingPixels(
                width: size.pixels.width,
                height: max(1, Int((Double(size.pixels.width) * aspect).rounded())))
        }
        return size.settingPixels(
            width: max(1, Int((Double(size.pixels.height) / aspect).rounded())),
            height: size.pixels.height)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let resampling = resampleCheckbox.state == .on
        if field === widthField || field === heightField {
            // Disabled fields post no change notification, so this only
            // fires while resampling; the guard says so rather than making
            // a reader work it out.
            guard resampling else { return }
            rebindPixels(from: field)
        } else if field === resolutionField {
            // The resolution never moves pixels, whether resampling or not:
            // it is the print size that follows it.
            let ppi = PrintSize.ppi(fromResolution: field.doubleValue, in: resolutionUnit)
            guard ppi.isFinite, ppi > 0 else { return }
            current = current.settingResolution(ppi)
        } else if field === printWidthField {
            // Resample on: the pixels are free, so the print size solves for
            // them. Resample off: the pixels are fixed, so it solves for the
            // resolution instead.
            guard let next = resampling
                ? current.resamplingToPrintWidth(field.doubleValue, in: lengthUnit)
                : current.settingPrintWidth(field.doubleValue, in: lengthUnit)
            else { return }
            current = resampling ? lockingAspect(next, drivenByWidth: true) : next
        } else if field === printHeightField {
            guard let next = resampling
                ? current.resamplingToPrintHeight(field.doubleValue, in: lengthUnit)
                : current.settingPrintHeight(field.doubleValue, in: lengthUnit)
            else { return }
            current = resampling ? lockingAspect(next, drivenByWidth: false) : next
        } else {
            return
        }
        syncFields(except: field)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        syncFields(except: nil)
    }

    private func rebindPixels(from field: NSTextField) {
        if field === widthField {
            let typed = widthField.integerValue
            guard typed > 0 else { return }
            current = lockingAspect(
                current.settingPixels(width: typed, height: current.pixels.height),
                drivenByWidth: true)
        } else {
            let typed = heightField.integerValue
            guard typed > 0 else { return }
            current = lockingAspect(
                current.settingPixels(width: current.pixels.width, height: typed),
                drivenByWidth: false)
        }
    }

    @objc private func resampleChanged(_ sender: Any?) {
        if resampleCheckbox.state == .off {
            // Pixels cannot change with Resample off, so anything typed into
            // the pixel fields has stopped being true: put the document's
            // own back before locking them.
            current = current.settingPixels(width: originalWidth, height: originalHeight)
        }
        syncEnabled()
        syncFields(except: nil)
    }

    @objc private func unitChanged(_ sender: Any?) {
        syncResolutionBounds()
        syncFields(except: nil)
    }

    // MARK: - Commit

    @objc private func applyClicked(_ sender: Any?) {
        let resampling = resampleCheckbox.state == .on
        // The pixel guards read the fields, not `current`, so an emptied
        // field still refuses rather than committing the last good value.
        let w = resampling ? widthField.integerValue : originalWidth
        let h = resampling ? heightField.integerValue : originalHeight
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
        // The core refuses a resize that would push the channel list past the
        // .rz pixel budget; say which channels and which budget (ChannelBudget)
        // instead of letting applyEdit beep.
        if let reason = document.doc?.channelBudgetRefusal(width: w, height: h) {
            presentChannelBudgetAlert(reason)
            return
        }

        let geometry: DocumentGeometry? =
            (w != originalWidth || h != originalHeight)
            ? .resize(width: w, height: h, filter: filter) : nil
        // `current` only leaves the document's own resolution behind when the
        // user edits the Resolution or Print size rows, so this is exactly
        // "the resolution changed" — with the core's own quantization applied
        // so an echoed value is not an edit.
        let resolution: (x: Double, y: Double)? =
            current.hasSameResolution(as: original) ? nil : current.ppi

        dismiss(self)
        document.applyEdit("Image Size") { doc in
            // Both halves chain through one closure so the dialog is one undo
            // step, and neither half changing returns nil — the app's rule
            // that a dialog which changes nothing registers no undo step.
            // Resizing never touches the resolution (Photoshop's "Resample
            // on": the pixels and the print size change, the ppi holds), so
            // the order of the two is free; geometry first keeps the
            // resolution edit the last word.
            var edited: RasterDocument? = nil
            if let geometry = geometry {
                guard let resized = doc.applyingDocumentGeometry(geometry) else { return nil }
                edited = resized
            }
            if let ppi = resolution,
               let retagged = (edited ?? doc).settingResolution(x: ppi.x, y: ppi.y) {
                edited = retagged
            }
            return edited
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(self)
    }
}
