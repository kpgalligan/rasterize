import AppKit

/// The right panel's fourth tab: the document's histogram over a readout of
/// the pixel under the cursor, the selection's bounds and area, and the
/// document's size, resolution and profile.
///
/// The readout follows the cursor live and FREEZES with its last value when
/// the cursor leaves the canvas, which is why nothing here clears it.
///
/// Two rules the rest of the file keeps. **The histogram is canvas-sized
/// work and never runs on the main thread**: every scan goes through the
/// panel's own `HistogramLoader`, and everything the scan needs — the image
/// handle, the selection struct, the stride — is resolved here, on the main
/// thread, and captured by VALUE, so the background queue never reaches back
/// into the document. And **the numbers are the document's own**: the RGB is
/// what the pixels hold, converted nowhere, and Lab goes through the
/// document's own profile, reading "—" rather than an sRGB guess when this
/// build cannot model that profile.
final class InfoPanelViewController: NSViewController {
    /// Which pixels the histogram counts. The current selection GATES
    /// whichever of these is chosen — it is not a third source — so the
    /// popup stays two items and the footnote says what the gate does.
    private enum Source: Int {
        case composite
        case activeLayer

        var title: String {
            switch self {
            case .composite: return "Composite"
            case .activeLayer: return "Active layer"
            }
        }
    }

    /// One line of the readout table. An enum rather than nine stored
    /// labels: the grid, the captions and the "clear it all" pass are then
    /// one loop each, and a row cannot exist in one of them and not the
    /// others.
    private enum Row: Int, CaseIterable {
        case position
        case rgb
        case hsb
        case lab
        case selection
        case area
        case size
        case resolution
        case profile

        var caption: String {
            switch self {
            case .position: return "Position"
            case .rgb: return "RGB"
            case .hsb: return "HSB"
            case .lab: return "Lab"
            case .selection: return "Selection"
            case .area: return "Area"
            case .size: return "Size"
            case .resolution: return "Resolution"
            case .profile: return "Profile"
            }
        }
    }

    /// Weak, like the other three panels: the document owns the window that
    /// owns the editor that owns this panel, so a strong reference here is a
    /// cycle that keeps a closed document alive.
    weak var document: ImageDocument?

    /// Tab switches, mirroring the other three panels.
    var onShowLayers: (() -> Void)?
    var onShowChannels: (() -> Void)?
    var onShowAssistant: (() -> Void)?

    /// The canvas's live selection, PULLED at the moment a scan starts
    /// (installed by `EditorViewController+Info.showInfoTab`).
    ///
    /// A pull rather than a push because a `CanvasSelection` is only wanted
    /// on the two occasions a scan begins, and pulling on the main thread
    /// and capturing the struct by value is what lets `maskBytes()` — a
    /// canvas-sized rasterization — run on the loader's queue with the rest
    /// of the scan. The editor pushes the cheap half (bounds, and the count
    /// when it knows it for free) through `setSelectionState` instead.
    var selectionProvider: (() -> CanvasSelection?)?

    private let histogramView = HistogramView()
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clippingLabel = NSTextField(labelWithString: "")
    private let footnote = NSTextField(wrappingLabelWithString: "")
    private var valueLabels: [Row: NSTextField] = [:]

    private let loader = HistogramLoader()
    private var source: Source = .composite
    private var isPanelVisible = false
    /// A scan that was asked for while the panel was hidden or while a
    /// gesture was live; consumed by `setPanelVisible` and by the gesture's
    /// final non-live post.
    private var needsHistogram = false
    /// Increments on every scan request, so a measurement that comes back
    /// after the selection has moved on is dropped rather than shown
    /// against the wrong marquee.
    private var scanGeneration = 0

    /// The last pixel the cursor reported, kept so a document change can
    /// re-read the same pixel — the readout follows an edit under a
    /// stationary cursor, which is how you watch a slider move a value.
    private var lastPixel: (x: Int, y: Int)?
    /// The last readout shown. Never cleared: the freeze rule.
    private var lastReadout: PixelReadout?
    private var selectionBounds: CGRect?
    /// The exact selected-pixel count: the editor's free answer when it has
    /// one, otherwise the loader's measurement, and nil while neither has
    /// arrived.
    private var selectedArea: Int?
    /// The stride the last scan used, for the "sampled" note.
    private var lastStride = 1

    /// The image the last scan resolved, memoized with the source and
    /// document it was resolved for.
    ///
    /// Resolving happens on the main thread AHEAD of the loader's debounce
    /// — it has to, because a handle may be touched by one queue at a time
    /// — and `setSelectionState` pushes once per `mouseDragged` of a
    /// marquee. Without this memo the "Active layer" source would run a
    /// canvas-sized `rz_doc_layer_canvas_image` per drag event (measured:
    /// 0.041 s on a 25 MP document, 0.162 s on a 100 MP one), which is
    /// exactly the per-tick canvas-sized read `AdjustmentSheet`'s
    /// `planePreview` comment warns against. The debounce coalesces the
    /// SCAN; this coalesces the RESOLVE. Invalidated by `documentDidChange`
    /// — the one event that changes the pixels — and by the key itself,
    /// since a different source, layer index or document simply misses.
    private var cachedImage: RasterImage?
    private var cachedImageKey: (source: HistogramSource, document: ObjectIdentifier)?

    private static let counts: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InfoPanelViewController does not support NSCoder")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Waits out an in-flight scan: it holds an image handle this panel
        // is the last owner of.
        loader.cancel()
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: DS.panelWidth, height: 400))
        root.wantsLayer = true
        root.layer?.backgroundColor = DS.chromeBackground.cgColor

        let tabs = PanelTabsView(
            titles: ["Layers", "Channels", "Assistant", "Info"], activeIndex: 3
        ) { [weak self] index in
            if index == 0 { self?.onShowLayers?() }
            if index == 1 { self?.onShowChannels?() }
            if index == 2 { self?.onShowAssistant?() }
        }
        tabs.translatesAutoresizingMaskIntoConstraints = false

        // Both popups carry their choice in `tag`, never in the item's
        // position, and are given their own menus rather than appending to
        // whatever a fresh NSPopUpButton happens to hold.
        let sourceMenu = NSMenu()
        for item in [Source.composite, Source.activeLayer] {
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            menuItem.tag = item.rawValue
            sourceMenu.addItem(menuItem)
        }
        sourcePopup.menu = sourceMenu
        sourcePopup.selectItem(withTag: source.rawValue)
        sourcePopup.controlSize = .small
        sourcePopup.font = DS.sans(11)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged(_:))
        sourcePopup.toolTip = "Which pixels the histogram counts"

        let displayMenu = NSMenu()
        for display in HistogramView.Display.allCases {
            let menuItem = NSMenuItem(title: display.displayName, action: nil, keyEquivalent: "")
            menuItem.tag = display.rawValue
            displayMenu.addItem(menuItem)
        }
        displayPopup.menu = displayMenu
        displayPopup.selectItem(withTag: histogramView.display.rawValue)
        displayPopup.controlSize = .small
        displayPopup.font = DS.sans(11)
        displayPopup.target = self
        displayPopup.action = #selector(displayChanged(_:))
        displayPopup.toolTip = "Which counts the plot draws"

        let popups = NSStackView(views: [sourcePopup, displayPopup])
        popups.orientation = .horizontal
        popups.distribution = .fillEqually
        popups.spacing = 6

        histogramView.translatesAutoresizingMaskIntoConstraints = false

        clippingLabel.font = DS.mono(10)
        clippingLabel.textColor = DS.textFaint
        clippingLabel.lineBreakMode = .byTruncatingTail
        clippingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        footnote.font = DS.sans(10)
        footnote.textColor = DS.textFaint

        let grid = NSGridView(views: Row.allCases.map { row in
            let caption = NSTextField(labelWithString: "")
            caption.attributedStringValue = DS.microLabel(row.caption)
            let value = NSTextField(labelWithString: "—")
            value.font = DS.mono(11)
            value.textColor = DS.textStrong
            value.lineBreakMode = .byTruncatingTail
            // The value column truncates rather than widening the grid past
            // the panel: a Display P3 profile name is longer than the panel
            // is wide, and a scroll bar for one row would be worse.
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            valueLabels[row] = value
            return [caption, value]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).width = 72
        grid.column(at: 1).xPlacement = .fill

        let column = NSStackView(views: [popups, histogramView, clippingLabel, grid, footnote])
        column.translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(4, after: histogramView)
        column.setCustomSpacing(14, after: clippingLabel)
        column.setCustomSpacing(14, after: grid)

        root.addSubview(tabs)
        root.addSubview(column)

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabs.heightAnchor.constraint(equalToConstant: DS.tabHeight),

            // The column is anchored at the top and left FREE at the bottom:
            // its rows have required intrinsic heights, so a bottom anchor
            // of any kind would go unsatisfiable in a short window and
            // AppKit would break a constraint of its own choosing instead.
            column.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            popups.widthAnchor.constraint(equalTo: column.widthAnchor),
            histogramView.widthAnchor.constraint(equalTo: column.widthAnchor),
            histogramView.heightAnchor.constraint(equalToConstant: 96),
            clippingLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            grid.widthAnchor.constraint(equalTo: column.widthAnchor),
            footnote.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentDidChange(_:)),
            name: .imageDocumentImageDidChange, object: document)
        loader.onBins = { [weak self] bins in self?.binsArrived(bins) }
        reloadDocumentRows()
        updateSelectionRows()
        updateFootnote()
        requestHistogram()
    }

    // MARK: - Document and panel state

    @objc private func documentDidChange(_ note: Notification) {
        // The Layers panel's rule, inverted for what this panel holds: a
        // live tick (a Move drag, an opacity scrub, a slider preview) is
        // exactly when a reader wants the one-pixel readout to follow, so
        // the cheap half refreshes every tick and only the canvas-sized
        // scan waits for the gesture's final non-live post.
        let isLive = (note.userInfo?["isLive"] as? Bool)
            ?? document?.isLiveEditing
            ?? false
        // The pixels moved, so the memoized source image is stale — on a
        // live tick too, where the scan is merely deferred.
        cachedImage = nil
        cachedImageKey = nil
        reloadDocumentRows()
        refreshReadout()
        guard !isLive else {
            needsHistogram = true
            return
        }
        requestHistogram()
    }

    /// Called whenever the panel is shown or hidden; a scan that was
    /// deferred while hidden happens here, and nothing canvas-sized runs
    /// while nobody can see the result.
    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        guard visible, needsHistogram else { return }
        requestHistogram()
    }

    /// The active layer moved, so the "Active layer" source is stale.
    ///
    /// The editor forwards its `layersPanel.onActiveLayerChange` to the
    /// Channels panel's twin of this method; the same one-line forward is
    /// what keeps this source live.
    func activeLayerChanged() {
        guard source == .activeLayer else { return }
        requestHistogram()
    }

    /// Pushed from the editor's `updateStatus()`, where every selection
    /// change already lands: the marquee's bounds and, when it is worth
    /// counting, the number of selected pixels.
    ///
    /// `area` is nil whenever the editor cannot answer for free (an
    /// ellipse, a lasso, a wand mask), and the loader then measures it in
    /// the same background pass that builds the mask the histogram is
    /// gated by — one canvas scan for both answers, per completed gesture.
    ///
    /// A nil `area` therefore CLEARS the count, whether or not the bounds
    /// moved. Keeping the last exact one while the bounds happen to match
    /// printed a confident lie: an ellipse dragged inside the box a
    /// rectangle just vacated covers about 7,854 of its 10,000 px, and the
    /// row would have gone on claiming 10,000 until the background scan
    /// landed. "—" until the measurement arrives is what the row below
    /// promises.
    func setSelectionState(bounds: CGRect?, area: Int?) {
        let changed = bounds != selectionBounds
        selectionBounds = bounds
        selectedArea = area
        guard isViewLoaded else { return }
        updateSelectionRows()
        updateFootnote()
        // A selection GATES the histogram, so a live one re-scans on every
        // push rather than only when its bounds move: bounds cannot tell a
        // rectangle from an ellipse inside the same box, nor one wand mask
        // from the next. The loader's debounce turns a burst — a marquee
        // drag posts one of these per mouse event — into a single scan.
        if changed || selectionBounds != nil { requestHistogram() }
    }

    /// The pixel under the cursor, or nil to leave the last one showing.
    func setCursor(_ readout: PixelReadout?) {
        guard let readout = readout else { return }
        lastPixel = (x: readout.x, y: readout.y)
        show(readout)
    }

    // MARK: - The readout rows

    private func show(_ readout: PixelReadout) {
        lastReadout = readout
        guard isViewLoaded else { return }
        valueLabels[.position]?.stringValue = "\(readout.x), \(readout.y)"
        // The hex carries the alpha byte when the pixel is not opaque —
        // the app's one canonical spelling of a sampled colour.
        valueLabels[.rgb]?.stringValue =
            "\(readout.r), \(readout.g), \(readout.b) · \(readout.hex)"
        let hsb = readout.hsbRounded
        valueLabels[.hsb]?.stringValue = "\(hsb.h)°, \(hsb.s)%, \(hsb.b)%"
        if let lab = readout.lab {
            valueLabels[.lab]?.stringValue = String(
                format: "%.1f, %.1f, %.1f", lab.l, lab.a, lab.b)
        } else {
            // Never an sRGB guess: the footnote says which profile the
            // core cannot model.
            valueLabels[.lab]?.stringValue = "—"
        }
        updateFootnote()
    }

    /// Re-reads the pixel the cursor last reported. An edit under a
    /// stationary cursor changes the pixel without moving it, and the
    /// panel is often open precisely to watch that number move.
    private func refreshReadout() {
        guard isViewLoaded, let pixel = lastPixel, let document = document else { return }
        guard let readout = PixelReadout.at(pixel, in: document, reach: 0) else { return }
        show(readout)
    }

    private func reloadDocumentRows() {
        guard isViewLoaded else { return }
        guard let doc = document?.doc else {
            valueLabels[.size]?.stringValue = "—"
            valueLabels[.resolution]?.stringValue = "—"
            valueLabels[.profile]?.stringValue = "—"
            return
        }
        valueLabels[.size]?.stringValue = "\(doc.width) × \(doc.height) px"
        valueLabels[.resolution]?.stringValue = PrintSize.resolutionText(doc.resolution)
        valueLabels[.profile]?.stringValue = doc.profileName
    }

    private func updateSelectionRows() {
        guard isViewLoaded else { return }
        guard let bounds = selectionBounds else {
            valueLabels[.selection]?.stringValue = "None"
            valueLabels[.area]?.stringValue = "—"
            return
        }
        valueLabels[.selection]?.stringValue =
            "\(Int(bounds.width)) × \(Int(bounds.height)) px at \(Int(bounds.minX)), "
            + "\(Int(bounds.minY))"
        guard let area = selectedArea else {
            // The measurement is on its way from the loader; a bounding-box
            // estimate would overstate an ellipse by a fifth, so the row
            // waits rather than lies.
            valueLabels[.area]?.stringValue = "—"
            return
        }
        var text = "\(Self.number(area)) px"
        if let doc = document?.doc, doc.width > 0, doc.height > 0 {
            let share = Double(area) / Double(doc.width * doc.height) * 100
            text += String(format: " · %.1f%% of canvas", share)
        }
        valueLabels[.area]?.stringValue = text
    }

    private func updateFootnote() {
        var parts = [
            "Readings are of the flattened composite, so a channel or plane target does not "
                + "change them."
        ]
        if selectionBounds != nil {
            parts.append("The histogram counts the selection only.")
        }
        if let readout = lastReadout, readout.lab == nil {
            parts.append(
                "Lab is unavailable: this build cannot model \(readout.labSpace), and an sRGB "
                    + "reading would be a made-up number.")
        }
        if let readout = lastReadout, !readout.paintExact {
            parts.append(
                "This pixel is outside sRGB, so \(readout.paintHex) is the closest a colour "
                    + "argument elsewhere can name it.")
        }
        // Only on a real change: the footnote is a wrapping label, and
        // re-setting it would relay out the column on every cursor move.
        let text = parts.joined(separator: " ")
        guard footnote.stringValue != text else { return }
        footnote.stringValue = text
    }

    // MARK: - The histogram

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, let next = Source(rawValue: tag) else { return }
        guard next != source else { return }
        source = next
        requestHistogram()
    }

    @objc private func displayChanged(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag,
              let display = HistogramView.Display(rawValue: tag)
        else { return }
        // A display change is a redraw of counts already in hand: no scan.
        histogramView.display = display
    }

    /// Starts one background scan. Everything the scan reads is resolved
    /// HERE and captured by value — the image handle, the selection struct,
    /// the stride — so the queue never touches the document, and the panel
    /// pays nothing at all while it is hidden or mid-gesture.
    private func requestHistogram() {
        guard isViewLoaded else { return }
        guard isPanelVisible, let document = document, let doc = document.doc else {
            needsHistogram = true
            return
        }
        guard !document.isLiveEditing else {
            needsHistogram = true
            return
        }
        needsHistogram = false
        let resolved: HistogramSource =
            source == .activeLayer ? .layer(document.activeLayerIndex) : .composite
        guard let image = resolvedImage(resolved, in: document) else {
            binsArrived(nil)
            return
        }
        let selection = selectionProvider?()
        // ~4 M pixels is enough for a stable shape; the panel re-scans on
        // every completed edit, so a 24 MP document must not re-read itself
        // in full each time.
        let stride = Histogram.liveStride(pixels: doc.width * doc.height, width: doc.width)
        lastStride = stride
        scanGeneration += 1
        let generation = scanGeneration
        loader.request { [weak self] in
            // maskBytes() rasterizes a canvas-sized buffer, which is the
            // whole reason the selection crosses as a struct rather than as
            // bytes taken on the main thread.
            let mask = selection?.maskBytes()
            if let mask = mask {
                // The selected-pixel count, free here because the mask is
                // already in hand: coverage >= 128, the same 50 % contour
                // rule the marquee and the core's histogram use.
                let area = mask.reduce(into: 0) { total, coverage in
                    if coverage >= 128 { total += 1 }
                }
                DispatchQueue.main.async { self?.areaMeasured(area, generation: generation) }
            }
            return Histogram.of(image, selection: mask, stride: stride)
        }
    }

    /// `source.image(in:)`, through the memo described on `cachedImage`. A
    /// miss re-resolves and re-keys; a nil result is not cached, because
    /// nothing was built to keep.
    private func resolvedImage(
        _ source: HistogramSource, in document: ImageDocument
    ) -> RasterImage? {
        let identity = ObjectIdentifier(document)
        if let key = cachedImageKey, key.source == source, key.document == identity,
           let image = cachedImage {
            return image
        }
        guard let image = source.image(in: document) else { return nil }
        cachedImage = image
        cachedImageKey = (source: source, document: identity)
        return image
    }

    private func areaMeasured(_ area: Int, generation: Int) {
        // A measurement of a marquee that has since moved is not an answer
        // about this one; the newer scan is already on its way.
        guard generation == scanGeneration, selectionBounds != nil else { return }
        selectedArea = area
        updateSelectionRows()
    }

    private func binsArrived(_ bins: HistogramBins?) {
        guard isViewLoaded else { return }
        histogramView.bins = bins
        guard let bins = bins, bins.total > 0 else {
            clippingLabel.stringValue = "No pixels to count"
            return
        }
        var text =
            "Clipped: \(Self.number(Int(bins.shadowClipped))) shadow · "
            + "\(Self.number(Int(bins.highlightClipped))) highlight"
        if bins.sampled {
            // The shape is the image's; the counts are a sample of it, and
            // a reader comparing two numbers deserves to know which.
            text += " · 1 in \(lastStride) sampled"
        }
        clippingLabel.stringValue = text
    }

    private static func number(_ value: Int) -> String {
        counts.string(from: NSNumber(value: value)) ?? String(value)
    }
}
