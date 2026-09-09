import AppKit

/// The RAW Develop dialog: a live preview and the thirteen controls
/// `CIRAWFilter` actually exposes, run app-modally BEFORE any pixels land.
///
/// A RAW is developed once, at open — there is no re-develop and no RAW
/// layer kind — so this is the only moment the choice can be made, and
/// Cancel opens nothing at all. It is an app-modal window rather than a
/// sheet because `ImageDocument.read(from:ofType:)` runs before there is a
/// window to hang a sheet from (`ModalCardWindowController` carries the
/// full reasoning).
///
/// The window owns no `CIRAWFilter`. Every preview closure captures the URL
/// and a `RawDevelopValues` — values only, never `self` — and builds its own
/// filter on `PreviewRenderer`'s queue, so nothing is reachable from two
/// threads and `cancel()`'s `queue.sync {}` cannot strand a half-configured
/// filter. The commit builds a fresh one on the main thread; two filters on
/// one URL are independent objects.
final class RawDevelopWindowController: NSObject {
    /// Puts the dialog up for `probe` and returns the settings to develop
    /// with, or nil when the user cancelled.
    static func run(_ probe: RawProbe) -> RawDevelopSettings? {
        RawDevelopWindowController(probe: probe).run()
    }

    /// One continuous control, described once so the thirteen rows are built,
    /// reset and enabled by the same three lines instead of thirteen copies.
    private struct Knob {
        let label: String
        let range: ClosedRange<Double>
        let format: (Double) -> String
        /// False when THIS file's decoder does not support the control: the
        /// row is disabled and still shows the file's own value, and the
        /// card's footnote names it.
        let supported: Bool
        /// True for temperature and tint, which are additionally gated on
        /// the white-balance pop-up being on Custom.
        let whiteBalance: Bool
        let read: (RawDevelopValues) -> Double
        let write: (inout RawDevelopValues, Double) -> Void
        /// True for Shadows, which `CIRAWFilter` documents as having no
        /// effect while `boostAmount` (Tone curve) is 0. The row is disabled
        /// there rather than left live: a slider that can be dragged across
        /// its whole range while the preview never moves is the one thing a
        /// live preview must not do.
        var inertWhileLinear = false
    }

    private let probe: RawProbe
    private var values: RawDevelopValues
    private let knobs: [Knob]
    private var knobRows: [CardControlRow] = []
    private var lensRow: CardControlRow?
    private var highlightRow: CardControlRow?
    private var whiteBalanceRow: CardControlRow?
    private let previewView = NSImageView()
    private let renderer = PreviewRenderer()
    private var modal: ModalCardWindowController?

    /// The preview's size. 516 pt is the 560 pt card less its 2 × 22
    /// insets, and 344 would be exactly 3:2 — the aspect ratio of nearly
    /// every camera RAW — so at 340 a landscape frame all but fills the box
    /// and a portrait one letterboxes symmetrically. Fixed rather than
    /// fitted, because the window must not change size when the picture
    /// behind it does.
    private static let previewSize = NSSize(width: 516, height: 340)

    /// How short the preview may get on a small screen (see
    /// `fitToScreen(_:)`). Below this it is no longer a preview.
    private static let minimumPreviewHeight: CGFloat = 160

    /// Room left for the title bar plus a margin above and below the
    /// window, since the card is measured without its window.
    private static let windowChrome: CGFloat = 60

    private var previewHeightConstraint: NSLayoutConstraint?

    private init(probe: RawProbe) {
        self.probe = probe
        let capabilities = probe.capabilities
        values = capabilities.defaults
        // The order here IS the dialog's top-to-bottom order and the order
        // RawCapabilities.unsupportedLabels lists the footnote in.
        knobs = [
            Knob(
                label: "Exposure:", range: RawDevelopRange.exposure,
                format: { String(format: "%+.2f EV", $0) }, supported: true,
                whiteBalance: false, read: { $0.exposure }, write: { $0.exposure = $1 }),
            Knob(
                label: "Temperature:", range: RawDevelopRange.temperature,
                format: { String(format: "%.0f K", $0) }, supported: true,
                whiteBalance: true, read: { $0.temperature }, write: { $0.temperature = $1 }),
            Knob(
                label: "Tint:", range: RawDevelopRange.tint,
                format: { String(format: "%.0f", $0) }, supported: true,
                whiteBalance: true, read: { $0.tint }, write: { $0.tint = $1 }),
            Knob(
                label: "Tone curve:", range: RawDevelopRange.toneCurve,
                format: { String(format: "%.2f", $0) }, supported: true,
                whiteBalance: false, read: { $0.toneCurve }, write: { $0.toneCurve = $1 }),
            Knob(
                label: "Shadows:", range: RawDevelopRange.shadows,
                format: { String(format: "%.2f", $0) }, supported: true,
                whiteBalance: false, read: { $0.shadows }, write: { $0.shadows = $1 },
                inertWhileLinear: true),
            Knob(
                label: "Local contrast:", range: RawDevelopRange.contrast,
                format: { String(format: "%.2f", $0) }, supported: capabilities.contrast,
                whiteBalance: false, read: { $0.contrast }, write: { $0.contrast = $1 }),
            Knob(
                label: "Sharpness:", range: RawDevelopRange.sharpness,
                format: { String(format: "%.2f", $0) }, supported: capabilities.sharpness,
                whiteBalance: false, read: { $0.sharpness }, write: { $0.sharpness = $1 }),
            Knob(
                label: "Detail:", range: RawDevelopRange.detail,
                format: { String(format: "%.2f", $0) }, supported: capabilities.detail,
                whiteBalance: false, read: { $0.detail }, write: { $0.detail = $1 }),
            Knob(
                label: "Luminance noise:", range: RawDevelopRange.luminanceNoise,
                format: { String(format: "%.2f", $0) }, supported: capabilities.luminanceNoise,
                whiteBalance: false, read: { $0.luminanceNoise },
                write: { $0.luminanceNoise = $1 }),
            Knob(
                label: "Colour noise:", range: RawDevelopRange.colorNoise,
                format: { String(format: "%.2f", $0) }, supported: capabilities.colorNoise,
                whiteBalance: false, read: { $0.colorNoise }, write: { $0.colorNoise = $1 }),
        ]
        super.init()
        renderer.onRender = { [weak self] image in
            guard let self = self, let image = image else { return }
            // .zero asks NSImage to take the CGImage's pixel dimensions as
            // its size, which is what the proportional scaling below wants.
            self.previewView.image = NSImage(cgImage: image, size: .zero)
        }
    }

    private func run() -> RawDevelopSettings? {
        let modal = ModalCardWindowController(title: "Develop RAW", card: makeCard())
        self.modal = modal
        requestPreview()
        let response = modal.runModal()
        // Waits out any in-flight decode before the settings are returned
        // and the document open continues on this same thread.
        renderer.cancel()
        self.modal = nil
        guard response == .OK else { return nil }
        return values.settings(against: probe.capabilities.defaults)
    }

    // MARK: - The card

    private func makeCard() -> NSView {
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.imageAlignment = .alignCenter
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = DS.canvasVoid.cgColor
        previewView.widthAnchor.constraint(
            equalToConstant: Self.previewSize.width).isActive = true
        let previewHeight = previewView.heightAnchor.constraint(
            equalToConstant: Self.previewSize.height)
        previewHeight.isActive = true
        previewHeightConstraint = previewHeight

        var rows: [NSView] = [previewView]
        let whiteBalance = cardPopupRow(
            label: "White balance:", titles: ["As Shot", "Custom"], selected: 0
        ) { [weak self] index in
            self?.setCustomWhiteBalance(index == 1)
        }
        whiteBalanceRow = whiteBalance

        var placedWhiteBalance = false
        for (index, knob) in knobs.enumerated() {
            let row = cardSliderRow(
                label: knob.label, min: knob.range.lowerBound, max: knob.range.upperBound,
                value: knob.read(values), format: knob.format
            ) { [weak self] value in
                self?.knobChanged(index, value)
            }
            knobRows.append(row)
            // The pop-up sits directly above the pair it governs.
            if knob.whiteBalance && !placedWhiteBalance {
                placedWhiteBalance = true
                rows.append(whiteBalance)
            }
            rows.append(row)
        }

        let lens = cardCheckboxRow(
            label: "Lens correction:", title: "Correct distortion and vignetting",
            on: values.lensCorrection
        ) { [weak self] on in
            self?.values.lensCorrection = on
            self?.requestPreview()
        }
        lensRow = lens
        rows.append(lens)

        // macOS 26+ only; gated because the deployment floor is 15. The row
        // is HIDDEN below 26 rather than disabled — a control that can never
        // come alive on this OS is noise, and the footnote is for controls
        // the FILE cannot support.
        if #available(macOS 26.0, *) {
            let highlights = cardCheckboxRow(
                label: "Highlights:", title: "Recover clipped highlights",
                on: values.highlightRecovery
            ) { [weak self] on in
                self?.values.highlightRecovery = on
                self?.requestPreview()
            }
            highlightRow = highlights
            rows.append(highlights)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        // The sheet grids' own row spacing, and `makeSheetView`'s own gap
        // between a card's parts — so a modal card reads as a sheet.
        stack.spacing = 10
        stack.setCustomSpacing(16, after: previewView)

        let reset = StickerButton(
            title: "Reset", style: .secondary, target: self, action: #selector(resetClicked(_:)))
        let cancel = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        // "Open", not "Apply": this dialog does not change a document, it
        // decides whether one comes into existence.
        let open = StickerButton(
            title: "Open", style: .primary, target: self, action: #selector(openClicked(_:)))
        var leading: [NSView] = [reset]
        let unsupported = probe.capabilities.unsupportedLabels
        if !unsupported.isEmpty {
            leading.append(
                sheetFootnote("This file does not support: "
                    + unsupported.joined(separator: ", ") + "."))
        }
        applyEnablement()
        let card = makeSheetView(
            title: "Develop \(probe.url.lastPathComponent)", hint: subtitle,
            content: stack,
            buttonRow: makeButtonRow(cancel: cancel, apply: open, leading: leading),
            // Wider than the house 420 pt card: a preview you cannot judge
            // an exposure or a white balance from is not worth showing, and
            // the two-pane Layer Style sheet already set the precedent for a
            // card that asks for more room when its content earns it.
            width: 560)
        fitToScreen(card)
        return card
    }

    /// Gives the preview back whatever height the screen cannot spare.
    ///
    /// Measured, the card stands 916 pt tall with the full 340 pt preview
    /// and the macOS 26 highlight row — comfortable on a default display
    /// mode, and more than a 13" laptop turned up to its largest text size
    /// has to give. There are thirteen controls and two buttons under the
    /// picture, none of which may fall off the bottom of a window that
    /// cannot scroll, so the picture is the part that yields.
    private func fitToScreen(_ card: NSView) {
        guard let constraint = previewHeightConstraint,
              let available = NSScreen.main?.visibleFrame.height
        else { return }
        let overflow = card.fittingSize.height + Self.windowChrome - available
        guard overflow > 0 else { return }
        constraint.constant = max(
            Self.minimumPreviewHeight, Self.previewSize.height - overflow)
    }

    /// "Canon EOS R5 · 8192 × 5464 pixels" — which file is being developed,
    /// which matters when a folder of RAWs was dropped and three dialogs are
    /// queued behind this one.
    private var subtitle: String {
        let size = String(
            format: "%.0f × %.0f pixels", probe.pixelSize.width, probe.pixelSize.height)
        guard let model = probe.cameraModel else { return size }
        return "\(model) · \(size)"
    }

    // MARK: - Control state

    private func knobChanged(_ index: Int, _ value: Double) {
        guard knobs.indices.contains(index) else { return }
        let knob = knobs[index]
        knob.write(&values, knob.range.clamping(value, fallback: knob.read(values)))
        // Tone curve gates Shadows, so every knob change re-asks: thirteen
        // rows is nothing beside the render this is about to schedule.
        applyEnablement()
        requestPreview()
    }

    private func setCustomWhiteBalance(_ custom: Bool) {
        values.customWhiteBalance = custom
        if !custom {
            // Back to As Shot: the sliders show the file's own numbers again,
            // and the decode writes neither property.
            values.temperature = probe.capabilities.defaults.temperature
            values.tint = probe.capabilities.defaults.tint
            for (index, knob) in knobs.enumerated() where knob.whiteBalance {
                knobRows[index].setValue(knob.read(values))
            }
        }
        applyEnablement()
        requestPreview()
    }

    /// A gated control whose flag is false is disabled and still shows the
    /// file's value; temperature and tint are additionally disabled while
    /// the white balance is As Shot, and Shadows while Tone curve is 0 —
    /// `boostShadowAmount` "has no effect if the boostAmount is 0"
    /// (CIRAWFilter.h), so the dead control reads as dead instead of moving
    /// a preview that cannot change.
    private func applyEnablement() {
        for (index, knob) in knobs.enumerated() {
            knobRows[index].isEnabled =
                knob.supported && (!knob.whiteBalance || values.customWhiteBalance)
                && (!knob.inertWhileLinear || values.toneCurve > 0)
        }
        lensRow?.isEnabled = probe.capabilities.lensCorrection
        highlightRow?.isEnabled = probe.capabilities.highlightRecovery
    }

    private func requestPreview() {
        let url = probe.url
        let values = self.values
        let capabilities = probe.capabilities
        // Read HERE, on the main thread, and captured by value: the render
        // closure runs on `PreviewRenderer`'s queue and may touch neither
        // `ColorSettings` nor `self`. This is the space the committed
        // document will hold (`ImageDocument.read` → `adoptWorkingSpace`), so
        // it is the space the preview is graded in — see `previewImage`.
        let space = ColorSettings.workingSpace.cgSpace
        renderer.request {
            RawImage.previewImage(
                url: url, values: values, capabilities: capabilities, space: space)
        }
    }

    // MARK: - Buttons

    @objc private func resetClicked(_ sender: Any?) {
        values = probe.capabilities.defaults
        for (index, knob) in knobs.enumerated() {
            knobRows[index].setValue(knob.read(values))
        }
        lensRow?.setOn(values.lensCorrection)
        highlightRow?.setOn(values.highlightRecovery)
        whiteBalanceRow?.setSelected(0)
        applyEnablement()
        requestPreview()
    }

    @objc private func openClicked(_ sender: Any?) {
        modal?.end(.OK)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        modal?.end(.cancel)
    }
}
