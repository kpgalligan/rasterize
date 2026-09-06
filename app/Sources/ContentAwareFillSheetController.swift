import AppKit

/// Edit > Content-Aware Fill…: the selection is filled with pixels invented
/// from a ring around it — a PatchMatch inpaint for the texture, then the
/// Poisson blend that puts that texture under the light it lands in — with a
/// live preview of the result before anything commits.
///
/// The lifecycle is `ApplyImageSheetController`'s five-step contract,
/// verbatim, and every step of it earns its place here:
///
/// 1. `init` captures the handles — `baseDoc`, the target layer AND a
///    fingerprint of it — so an agent edit arriving while the sheet is open
///    cannot move the ground under the preview, and captures **the
///    selection's coverage bytes once**. All three are handed to Apply, not
///    just to the preview: a document-modal sheet does not stop the main run
///    loop, so an MCP `set_active_layer` or `select_rect` can land behind it,
///    and committing a layer or a region the user never saw previewed is
///    exactly the drift the capture exists to prevent. The fingerprint is
///    what covers `delete_layer`, which the index alone cannot: deleting a
///    layer below the captured one leaves the index in range and pointing at
///    a different layer.
///    `maskBytes()` allocates a canvas-sized plane and rasterizes the
///    selection's path through CoreGraphics; doing that per control tick, on
///    the main thread, ahead of the debounce, is what hangs a dialog on a
///    large canvas.
/// 2. The preview goes through the shared `PreviewRenderer` (60 ms debounce,
///    coalescing) and its closure captures **values only** — the base handle,
///    the mask array and the three parameters. `self` never crosses onto the
///    queue, so nothing the closure touches can be mutated behind it.
/// 3. First paint in `viewDidAppear` behind `didRequestInitialPreview`: the
///    defaults are a real change, not an identity, so what the sheet shows
///    on opening is already what Apply would produce.
/// 4. Teardown order is fixed: `renderer.cancel()` → `previewImage = nil` →
///    `dismiss(self)` → commit. `cancel()` blocks the main thread waiting out
///    the one in-flight render (Rz handles are not thread-safe and Apply is
///    about to touch the same one), which is affordable only because the core
///    bounds a preview by WORK: the pipeline runs on windows reduced until
///    the CALL's covered count is under 40 000 pixels, and — because a small
///    part cannot be reduced at all and still costs milliseconds — it fills
///    at most the biggest 200 parts and leaves the rest showing the original.
///    Measured, that is 0.28 s for a megapixel hole in one part, 0.72 s for
///    900 specks and 0.80 s for twenty-five 200 x 200 blobs, where the fills
///    they preview take three to nine seconds. Without the part cap a
///    scattered selection previewed at full resolution and this Cancel
///    blocked for the whole of a fill: 2.3 s for those 900 specks, and 9.8 s
///    for the largest speck selection the caps admit.
/// 5. The view is built from `Sheets.swift`'s shared builders alone, so this
///    dialog looks like every other one.
///
/// The fill itself is `RasterDocument.contentAwareFilled`; Apply hands the
/// values — and the captured layer — to
/// `EditorViewController.applyContentAwareFill`, which re-runs it on the
/// document's CURRENT handle. This file is the dialog, its preview and its
/// parameters, nothing else.
final class ContentAwareFillSheetController: NSViewController {
    private weak var editor: EditorViewController?
    private weak var canvas: ImageCanvasView?
    /// The handle the preview runs on, captured when the sheet opened. Apply
    /// re-runs the same fill on the document's current handle.
    private let baseDoc: RasterDocument?
    /// The layer the fill writes, captured at open so a layers-panel click
    /// behind the sheet cannot move the goalposts mid-dialog.
    private let targetLayer: Int
    /// What that layer looked like when it was captured. The INDEX alone is
    /// not an identity — a `delete_layer` behind the sheet renumbers
    /// everything above it and the index then names a different layer — so
    /// Apply hands this back and refuses if the layer under the index no
    /// longer answers the same thing (`RasterDocument.layerFingerprint`).
    private let targetFingerprint: String?
    /// The selection's canvas-sized coverage bytes, rasterized ONCE (step 1).
    /// nil when nothing is selected, which disables Apply.
    private let mask: [UInt8]?

    private let ringField = NSTextField(string: "")
    private let sampleAllCheckbox = NSButton(
        checkboxWithTitle: "Sample All Layers", target: nil, action: nil)
    private let seedField = NSTextField(string: "")
    private let renderer = PreviewRenderer()
    private var didRequestInitialPreview = false

    /// The ring the sheet offers, in px. The floor is the core's own — three
    /// patch widths, 21 px, the narrowest band a source patch has anywhere to
    /// move in — and `requested_ring` raises anything below it, so a smaller
    /// number here would be a field showing a value the fill would not use.
    /// The ceiling is the core's too: past 512 px the fill has stopped
    /// sampling the blemish's neighbourhood and is sampling the photograph.
    private static let ringRange = 21...512
    /// The seed's range. The core takes a `UInt64`, but a field a person
    /// types into wants a number they can read back and retype, and 32 bits
    /// of seed is already far more distinct fills than anyone will try.
    private static let seedMax = 4_294_967_295
    /// Wide enough for "4294967295" in the 13pt mono field.
    private static let fieldWidth: CGFloat = 108

    init(editor: EditorViewController) {
        self.editor = editor
        self.canvas = editor.canvas
        self.baseDoc = editor.document?.doc
        let layer = editor.document?.activeLayerIndex ?? 0
        self.targetLayer = layer
        self.targetFingerprint = editor.document?.doc?.layerFingerprint(layer)
        self.mask = editor.canvas.selection?.maskBytes()
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ContentAwareFillSheetController does not support NSCoder")
    }

    override func loadView() {
        // The sheet's own persisted values, like a tool's options: the
        // command has no tool of its own to hang them on, and a ring width
        // that suited one photograph usually suits the next.
        let options = ToolOptionsStore.shared.contentAwareFill

        let ringFormatter = NumberFormatter()
        ringFormatter.numberStyle = .none
        ringFormatter.allowsFloats = false
        ringFormatter.minimum = NSNumber(value: Self.ringRange.lowerBound)
        ringFormatter.maximum = NSNumber(value: Self.ringRange.upperBound)
        ringField.formatter = ringFormatter
        ringField.stringValue = String(Self.clampRing(Int(options.ring.rounded())))
        ringField.target = self
        ringField.action = #selector(valueChanged(_:))
        ringField.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        DSField.style(ringField)

        let seedFormatter = NumberFormatter()
        seedFormatter.numberStyle = .none
        seedFormatter.allowsFloats = false
        seedFormatter.minimum = 0
        seedFormatter.maximum = NSNumber(value: Self.seedMax)
        seedField.formatter = seedFormatter
        seedField.stringValue = String(Self.clampSeed(options.seed))
        seedField.target = self
        seedField.action = #selector(valueChanged(_:))
        seedField.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        DSField.style(seedField)

        sampleAllCheckbox.state = options.sampleAllLayers ? .on : .off
        sampleAllCheckbox.font = DS.sans(13)
        sampleAllCheckbox.target = self
        sampleAllCheckbox.action = #selector(valueChanged(_:))

        let newSeedButton = StickerButton(
            title: "New", style: .secondary, target: self, action: #selector(newSeed(_:)))

        let grid = NSGridView(views: [
            [fieldLabel("Sample ring:"), row([ringField, unitLabel("px")])],
            [NSGridCell.emptyContentView, sampleAllCheckbox],
            [fieldLabel("Seed:"), row([seedField, newSeedButton])],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 106

        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        applyButton.isEnabled = canApply
        view = makeSheetView(
            title: "Content-aware fill", hint: hintText, content: grid,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [sheetFootnote("≤ 1 MP selection · ≤ 4 MP + ring · ≤ 80 MP boxes")]))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The defaults fill the selection — a real change, not an identity
        // like an adjustment slider's zero — so the preview is due
        // immediately.
        guard !didRequestInitialPreview else { return }
        didRequestInitialPreview = true
        requestPreview()
    }

    // MARK: - State

    /// False without a document, without a selection, and for a selection
    /// whose coverage plane does not match the document (a canvas resize
    /// behind the sheet). The menu item is already disabled without a
    /// selection; this is the same rule where the sheet can act on it.
    private var canApply: Bool {
        guard let doc = baseDoc, let mask = mask else { return false }
        return mask.count == doc.width * doc.height
    }

    /// The wrapping hint is the one label in the card with room for
    /// sentences, so it carries the four facts a person needs BEFORE
    /// pressing Apply: what the fill does, that the preview is a reduced-
    /// resolution stand-in for a full-size blend, that a narrow ring is
    /// widened for them, and the caps with the several-second warning that
    /// comes with them. The footnote repeats the caps as numbers because it
    /// is what stays on screen next to the button.
    private var hintText: String {
        let base =
            "Fills the selection from a ring of pixels around it and blends the result to "
            + "the surrounding light. The preview is computed at reduced resolution, and on "
            + "a selection of many small parts it fills the biggest 200 and leaves the rest "
            + "showing the original — the structure is final, the finest texture is not, and "
            + "the full-size blend runs on Apply. A ring narrower than the selection is "
            + "widened automatically, because a narrow ring offers too few distinct patches "
            + "and the fill tiles. At "
            + "most 1,000,000 selected pixels, 4,000,000 including the ring and 80 million "
            + "for the boxes the separate parts sit in, counting "
            + "every separate part of the selection together — a scatter of small parts "
            + "reaches the later limits first, since each carries its own ring and its own "
            + "box. What costs time is the "
            + "region PLUS its ring and the boxes the parts sit in, not the number of pixels "
            + "selected: a 300 x 300 region is half a second and a megapixel about five, but "
            + "a long thin scratch can cost several seconds for a few thousand selected "
            + "pixels. The most a permitted fill can cost is about twelve seconds, and the "
            + "app is unresponsive while it runs."
        guard !canApply else { return base }
        return base + " Nothing is selected, so Apply is disabled: make a selection first."
    }

    private static func clampRing(_ value: Int) -> Int {
        min(max(value, ringRange.lowerBound), ringRange.upperBound)
    }

    private static func clampSeed(_ value: Int) -> Int {
        min(max(value, 0), seedMax)
    }

    /// The ring the fields hold, clamped and echoed back so the field can
    /// never show a number the fill would not use.
    private func ringValue() -> Int {
        let value = Self.clampRing(ringField.integerValue)
        ringField.stringValue = String(value)
        return value
    }

    private func seedValue() -> UInt64 {
        let value = Self.clampSeed(seedField.integerValue)
        seedField.stringValue = String(value)
        return UInt64(value)
    }

    // MARK: - Preview

    /// The fill as the canvas should show it: `preview: true`, whose whole
    /// pipeline runs on a reduced window, flattened into the document's own
    /// space.
    ///
    /// The closure captures values — the base handle, the mask array and the
    /// three parameters — and never `self` or the live document, so nothing
    /// it reads can change while it runs on the renderer's queue.
    private func requestPreview() {
        guard let baseDoc = baseDoc, let mask = mask, canApply else { return }
        let layer = targetLayer
        let ring = ringValue()
        let seed = seedValue()
        let sampleAll = sampleAllCheckbox.state == .on
        renderer.request {
            // A refusal — a selection over the cap, a neighbourhood with
            // nothing to sample — previews the untouched composite, which is
            // the honest picture of "nothing would change here". The message
            // is not swallowed: Apply runs the same call at full size and
            // puts the core's own sentence in an alert.
            var result = baseDoc
            do {
                if let filled = try baseDoc.contentAwareFilled(
                    layer, mask: mask, ring: ring, seed: seed,
                    sampleAllLayers: sampleAll, preview: true)
                {
                    result = filled
                }
            } catch {
                result = baseDoc
            }
            return result.flattened()?.makeCGImage(in: result.colorSpace)
        }
    }

    // MARK: - Layout helpers

    /// One grid cell holding several controls on a line — the 106pt label
    /// column and the 420pt card leave 258pt for it.
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func unitLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = DS.sans(13)
        label.textColor = DS.textMuted
        return label
    }

    // MARK: - Actions

    @objc private func valueChanged(_ sender: Any?) {
        requestPreview()
    }

    /// Re-rolls the seed: a different plausible fill of the same selection,
    /// which is the only way to ask for one — everything else about the op
    /// is deterministic.
    @objc private func newSeed(_ sender: Any?) {
        seedField.stringValue = String(Int.random(in: 0...Self.seedMax))
        requestPreview()
    }

    @objc private func applyClicked(_ sender: Any?) {
        guard canApply, let mask = mask else {
            NSSound.beep()
            return
        }
        let ring = ringValue()
        let seed = seedValue()
        let sampleAll = sampleAllCheckbox.state == .on
        ToolOptionsStore.shared.contentAwareFill = ContentAwareFillOptions(
            ring: Double(ring), sampleAllLayers: sampleAll, seed: Int(seed))
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        // The layer the preview ran on, not whatever is active now: see the
        // type's step 1.
        editor?.applyContentAwareFill(
            layer: targetLayer, fingerprint: targetFingerprint, mask: mask,
            ring: Double(ring), sampleAllLayers: sampleAll, seed: seed)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}
