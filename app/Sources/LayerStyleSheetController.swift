import AppKit

/// Layer > Layer Style… — the ONE sheet for a layer's effects and blending
/// options: a checklist down the left (Blending Options, then the nine
/// effects, each with its checkbox) and one pane on the right for the
/// selected row, live-previewed through the normal projection — the core
/// renders the effects, so what the canvas shows while the sheet is up is
/// exactly what Apply commits, as one undo step.
///
/// Its own file because Sheets.swift is frozen; it is built on the shared
/// `makeSheetView` (at 640 pt through the builder's `width:`), so it matches
/// every other dialog. The panes are the `<Effect>Pane` classes, one file
/// each; only the Blending Options pane lives here.
final class LayerStyleSheetController: NSViewController {
    /// A checklist row.
    private enum Row: Equatable {
        case blendingOptions
        case effect(LayerStyleEffectKind)
    }

    /// 640 pt: the checklist (176) + 16 + the pane host (404) inside the
    /// builder's 22 pt insets — every pane grid (106 + 12 + 180 + 12 + 52 =
    /// 362) fits with room for a merged checkbox title.
    private static let cardWidth: CGFloat = 640
    private static let listWidth: CGFloat = 176
    private static let paneWidth: CGFloat = 404
    /// Tall enough for the nine-row Drop Shadow pane, so switching panes
    /// normally leaves the sheet's height alone; a taller pane still grows it.
    private static let paneMinHeight: CGFloat = 320

    private let document: ImageDocument
    private weak var canvas: ImageCanvasView?
    private let layerIndex: Int

    /// The preview base and what Cancel must leave behind, captured at init:
    /// the sheet blocks every other UI edit while it is open (agent edits
    /// are re-validated at Apply).
    private let baseDoc: RasterDocument?
    private let original: LayerStyle?
    private let originalLight: GlobalLight

    private var style: LayerStyle
    private var light: GlobalLight
    private let renderer = PreviewRenderer()
    /// The last preview document: each tick styles the PREVIOUS preview
    /// rather than the base, so the core's cache hand-over (set_layer_style
    /// moves the rendered planes from the style being replaced to its
    /// successor — a colour, opacity or blend edit is re-stamped, only an
    /// effect whose geometry changed is re-rendered) makes a slider drag
    /// cost no blur, and Apply commits from it with its planes warm.
    private let chain = PreviewChain()
    private var didRequestInitialPreview = false

    private var selectedRow: Row
    private var listRows: [(row: Row, view: StyleListRow)] = []
    private var effectPanes: [LayerStyleEffectKind: LayerStylePane] = [:]
    private var blendingPane: BlendingOptionsPane?
    private let paneHost = NSView()
    private var visiblePane: LayerStylePane?

    init(
        document: ImageDocument, canvas: ImageCanvasView?, layer: Int,
        initial: LayerStyleEffectKind?
    ) {
        self.document = document
        self.canvas = canvas
        self.layerIndex = layer
        let base: RasterDocument? = document.doc
        let original = base?.layerStylePayload(layer)
        let originalLight = base?.globalLight ?? GlobalLight()
        var style = original ?? LayerStyle()
        // Opening on a specific effect turns it on (Photoshop's menu items
        // do the same), so the first preview already shows it.
        if let initial = initial, !style.effectEnabled(initial) {
            style.setEffectEnabled(initial, true)
        }
        self.baseDoc = base
        self.original = original
        self.originalLight = originalLight
        self.style = style
        self.light = originalLight
        self.selectedRow = initial.map { .effect($0) } ?? .blendingOptions
        super.init(nibName: nil, bundle: nil)
        renderer.onRender = { [weak self] cgImage in
            self?.canvas?.previewImage = cgImage
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LayerStyleSheetController does not support NSCoder")
    }

    override func loadView() {
        var rowViews: [NSView] = []
        let blending = StyleListRow(title: "Blending Options", hasCheckbox: false)
        blending.onSelect = { [weak self] in self?.select(.blendingOptions) }
        listRows.append((.blendingOptions, blending))
        rowViews.append(blending)
        for kind in LayerStyleEffectKind.allCases {
            let row = StyleListRow(title: kind.title, hasCheckbox: true)
            row.onSelect = { [weak self] in self?.selectEffect(kind) }
            row.onToggle = { [weak self] on in self?.setEffectEnabled(kind, on) }
            listRows.append((.effect(kind), row))
            rowViews.append(row)
        }
        let list = NSStackView(views: rowViews)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.widthAnchor.constraint(equalToConstant: Self.listWidth).isActive = true

        paneHost.translatesAutoresizingMaskIntoConstraints = false
        paneHost.widthAnchor.constraint(equalToConstant: Self.paneWidth).isActive = true
        paneHost.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.paneMinHeight)
            .isActive = true
        // Low priority: the host settles at the minimum unless a pane needs
        // more, which keeps the height determinate.
        let preferred = paneHost.heightAnchor.constraint(equalToConstant: Self.paneMinHeight)
        preferred.priority = .defaultLow
        preferred.isActive = true

        let content = NSStackView(views: [list, paneHost])
        content.orientation = .horizontal
        content.alignment = .top
        content.spacing = 16

        let resetButton = StickerButton(
            title: "Reset", style: .secondary, target: self, action: #selector(resetClicked(_:)))
        let cancelButton = sheetCancelButton(target: self, action: #selector(cancelClicked(_:)))
        let applyButton = sheetApplyButton(target: self, action: #selector(applyClicked(_:)))
        view = makeSheetView(
            title: "Layer Style",
            hint: "Effects render from the layer's shape — its alpha times its mask — every time "
                + "the canvas composites, so they follow every move and edit. Fill opacity "
                + "scales the pixels but not the effects.",
            content: content,
            buttonRow: makeButtonRow(
                cancel: cancelButton, apply: applyButton,
                leading: [resetButton, sheetFootnote("one undo step")]),
            width: Self.cardWidth)
        refreshChecklist()
        select(selectedRow)
    }

    /// Preview immediately, so what the canvas shows is what Apply produces
    /// even before the first control moves.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didRequestInitialPreview else { return }
        didRequestInitialPreview = true
        requestPreview()
    }

    // MARK: - Checklist

    private func select(_ row: Row) {
        selectedRow = row
        for entry in listRows {
            entry.view.isSelected = entry.row == row
        }
        let pane = self.pane(for: row)
        pane.reload()
        showPane(pane)
    }

    /// Clicking an effect's NAME turns it on as well as showing its pane
    /// (Photoshop's gesture) — a pane editing an effect the preview does not
    /// show would be confusing.
    private func selectEffect(_ kind: LayerStyleEffectKind) {
        if !style.effectEnabled(kind) {
            style.setEffectEnabled(kind, true)
            styleDidChange()
        }
        select(.effect(kind))
    }

    private func setEffectEnabled(_ kind: LayerStyleEffectKind, _ on: Bool) {
        style.setEffectEnabled(kind, on)
        styleDidChange()
    }

    private func refreshChecklist() {
        for entry in listRows {
            if case .effect(let kind) = entry.row {
                entry.view.isChecked = style.effectEnabled(kind)
            }
        }
    }

    private func showPane(_ pane: LayerStylePane) {
        visiblePane?.view.removeFromSuperview()
        visiblePane = pane
        let paneView = pane.view
        paneView.translatesAutoresizingMaskIntoConstraints = false
        paneHost.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: paneHost.topAnchor),
            paneView.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
            paneView.trailingAnchor.constraint(lessThanOrEqualTo: paneHost.trailingAnchor),
            paneView.bottomAnchor.constraint(lessThanOrEqualTo: paneHost.bottomAnchor),
        ])
    }

    // MARK: - Panes

    private func pane(for row: Row) -> LayerStylePane {
        switch row {
        case .blendingOptions:
            if let pane = blendingPane { return pane }
            let pane = BlendingOptionsPane(
                fill: EffectBinding(
                    get: { [weak self] in self?.style.fillOpacity ?? 1 },
                    set: { [weak self] value in
                        self?.style.fillOpacity = value
                        self?.styleDidChange()
                    }),
                blendIf: EffectBinding(
                    get: { [weak self] in self?.style.blendIf },
                    set: { [weak self] value in
                        self?.style.blendIf = value
                        self?.styleDidChange()
                    }),
                context: paneContext)
            blendingPane = pane
            return pane
        case .effect(let kind):
            if let pane = effectPanes[kind] { return pane }
            let pane = makePane(for: kind)
            effectPanes[kind] = pane
            return pane
        }
    }

    private func makePane(for kind: LayerStyleEffectKind) -> LayerStylePane {
        let context = paneContext
        switch kind {
        case .dropShadow:
            return DropShadowPane(
                binding: binding(\.dropShadow, default: DropShadowEffect()), context: context)
        case .innerShadow:
            return InnerShadowPane(
                binding: binding(\.innerShadow, default: InnerShadowEffect()), context: context)
        case .outerGlow:
            return OuterGlowPane(
                binding: binding(\.outerGlow, default: OuterGlowEffect()), context: context)
        case .innerGlow:
            return InnerGlowPane(
                binding: binding(\.innerGlow, default: InnerGlowEffect()), context: context)
        case .stroke:
            return StrokePane(binding: binding(\.stroke, default: StrokeEffect()), context: context)
        case .colorOverlay:
            return ColorOverlayPane(
                binding: binding(\.colorOverlay, default: ColorOverlayEffect()), context: context)
        case .gradientOverlay:
            return GradientOverlayPane(
                binding: binding(\.gradientOverlay, default: GradientOverlayEffect()),
                context: context)
        case .bevelEmboss:
            return BevelEmbossPane(
                binding: binding(\.bevelEmboss, default: BevelEmbossEffect()), context: context)
        case .satin:
            return SatinPane(binding: binding(\.satin, default: SatinEffect()), context: context)
        }
    }

    /// A binding to one effect slot: reads the effect (its defaults while
    /// absent) and writes it back, re-previewing.
    private func binding<Effect>(
        _ keyPath: WritableKeyPath<LayerStyle, Effect?>,
        default makeDefault: @autoclosure @escaping () -> Effect
    ) -> EffectBinding<Effect> {
        EffectBinding(
            get: { [weak self] in self?.style[keyPath: keyPath] ?? makeDefault() },
            set: { [weak self] value in
                self?.style[keyPath: keyPath] = value
                self?.styleDidChange()
            })
    }

    private var paneContext: LayerStylePaneContext {
        LayerStylePaneContext(
            globalLight: EffectBinding(
                get: { [weak self] in self?.light ?? GlobalLight() },
                set: { [weak self] value in self?.lightDidChange(value) }),
            canvasSize: baseDoc?.canvasSize ?? .zero)
    }

    /// A global-light edit from a pane's Angle/Altitude slider. The pane
    /// that wrote it already shows the value, and the other panes re-read
    /// the light when they are next shown, so no reload happens here — a
    /// reload mid-drag would snap the slider under the pointer.
    private func lightDidChange(_ light: GlobalLight) {
        self.light = light
        styleDidChange()
    }

    private func styleDidChange() {
        refreshChecklist()
        requestPreview()
    }

    // MARK: - Preview and commit

    /// The edited style and light on the last preview (the captured base
    /// for the first), flattened on the renderer's queue — only captured
    /// values and the chain cross.
    private func requestPreview() {
        guard let baseDoc = baseDoc else { return }
        let style = self.style
        let light = self.light
        let idx = layerIndex
        let chain = self.chain
        renderer.request {
            // `try?` on a throwing `RasterDocument?` flattens to
            // `RasterDocument?`; nil means "same style as the previous
            // preview" (the core's equal-value refusal) or an invalid style,
            // and either way the previous preview is the right thing to
            // draw. The light setter refuses an unchanged value the same
            // way, and is always asked so a light edited and then put back
            // is put back on the chain too.
            let previous = chain.last ?? baseDoc
            let styled = (try? previous.withLayerStylePayload(idx, style)) ?? previous
            let lit = styled.withGlobalLight(light) ?? styled
            chain.last = lit
            // The styled composite is document pixels: tagged with that
            // document's own space so the preview and the canvas behind it
            // agree. `lit` is derived from `baseDoc`, so it carries the
            // same profile.
            return lit.flattened()?.makeCGImage(in: lit.colorSpace)
        }
    }

    @objc private func resetClicked(_ sender: Any?) {
        style = original ?? LayerStyle()
        light = originalLight
        refreshChecklist()
        visiblePane?.reload()
        requestPreview()
    }

    @objc private func applyClicked(_ sender: Any?) {
        let style = self.style
        let light = self.light
        let originalLight = self.originalLight
        let idx = layerIndex
        let baseDoc = self.baseDoc
        let chain = self.chain
        // cancel() drains the renderer's queue, so the chain is quiescent
        // from here on.
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
        // An identity style clears (the core's rule; normalized here so the
        // "nothing changed" compare is exact for an unstyled layer).
        let target: LayerStyle? = style.isIdentity ? nil : style
        guard target != original || light != originalLight else { return }
        // Two tools, one commit: the sheet writes the layer's style and the
        // document's global light together, and `[ActionStep]` is an array
        // exactly so one gesture can record both. The light is recorded only
        // when it moved, since it is document-wide.
        var record: [ActionStep] = .setLayerStyle(
            json: target?.json(), layerNamed: document.doc?.layerInfo(idx)?.name,
            note: target == nil ? "Layer ▸ Layer Style (cleared)" : "Layer ▸ Layer Style…")
        if light != originalLight {
            record += .setGlobalLight(angle: light.angle, altitude: light.altitude)
        }
        document.applyEdit("Layer Style", record: record) { doc in
            // The layer must still be what the sheet opened on: agent edits
            // can land under a sheet and move the stack.
            guard idx < doc.layerCount, !doc.layerIsAdjustment(idx) else { return nil }
            // Commit from the last preview while the document is still the
            // one it was rendered on: its planes are warm, so Apply
            // re-renders nothing the preview already showed. Both setters
            // refuse an unchanged value, so a preview that already matches
            // is committed as is (a pending tick may not have run).
            let start = (doc === baseDoc ? chain.last : nil) ?? doc
            var out = (try? start.withLayerStylePayload(idx, target)) ?? start
            out = out.withGlobalLight(light) ?? out
            return out === doc ? nil : out
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        renderer.cancel()
        canvas?.previewImage = nil
        dismiss(self)
    }
}

// MARK: - Preview chain

/// The document the last preview was rendered from, handed from one
/// renderer-queue tick to the next and read on the main thread at Apply
/// (after `PreviewRenderer.cancel()` has drained the queue). Locked so the
/// two threads can never race even if that ordering changes.
private final class PreviewChain {
    private let lock = NSLock()
    private var doc: RasterDocument?

    var last: RasterDocument? {
        get { lock.withLock { doc } }
        set { lock.withLock { doc = newValue } }
    }
}

// MARK: - Checklist row

/// One checklist row: a checkbox (none for Blending Options) and the title,
/// drawn by the row itself so a click anywhere on the title selects it.
/// Selected rows get the layers panel's highlight (DS.selectionFill plus a
/// 1 px DS.accent ring).
private final class StyleListRow: NSView {
    private let checkbox: NSButton?
    private let title: String

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    var isChecked: Bool {
        get { checkbox?.state == .on }
        set { checkbox?.state = newValue ? .on : .off }
    }

    var onSelect: (() -> Void)?
    var onToggle: ((Bool) -> Void)?

    init(title: String, hasCheckbox: Bool) {
        self.title = title
        self.checkbox = hasCheckbox ? NSButton(checkboxWithTitle: "", target: nil, action: nil) : nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        if let checkbox = checkbox {
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            checkbox.target = self
            checkbox.action = #selector(toggled(_:))
            addSubview(checkbox)
            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StyleListRow does not support NSCoder")
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            DS.selectionFill.setFill()
            path.fill()
            path.lineWidth = 1
            DS.accent.setStroke()
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.sans(13, weight: isSelected ? .semibold : .regular),
            .foregroundColor: isSelected ? DS.accent : DS.textStrong,
        ]
        let size = title.size(withAttributes: attributes)
        let x: CGFloat = checkbox == nil ? 12 : 30
        title.draw(
            at: NSPoint(x: x, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func toggled(_ sender: Any?) {
        onToggle?(checkbox?.state == .on)
    }
}

// MARK: - Blending Options pane

/// Blending Options: fill opacity (the pixels only, never the effects) over
/// the embedded Blend If pane.
private final class BlendingOptionsPane: NSObject, LayerStylePane {
    let view: NSView
    private let rows: [PaneRow]
    private let blendIfPane: BlendIfPane

    init(
        fill: EffectBinding<Double>, blendIf: EffectBinding<BlendIf?>,
        context: LayerStylePaneContext
    ) {
        let fillRow = PaneRows.percent(
            "Fill Opacity:", get: { fill.read() }, set: { fill.write($0) })
        rows = [fillRow]
        blendIfPane = BlendIfPane(binding: blendIf, context: context)
        let heading = fieldLabel("Blend If")
        let stack = NSStackView(views: [PaneRows.grid(rows), heading, blendIfPane.view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        view = stack
        super.init()
    }

    func reload() {
        rows.forEach { $0.reload() }
        blendIfPane.reload()
    }
}
