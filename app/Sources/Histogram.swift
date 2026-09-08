import AppKit

/// 256 bins each for red, green, blue and Rec. 709 luma over one image, plus
/// what a clipping warning needs. Built by the core
/// (`rz_image_histogram` through `RasterImage.histogram`): a pixel counts
/// when its alpha is non-zero and, with a selection, its coverage is 128 or
/// more — the 50 % contour rule the marquee uses everywhere else. `total` is
/// the number of pixels actually COUNTED, so a strided scan's proportions
/// read the same as a full one's.
struct HistogramBins {
    let red: [UInt32]
    let green: [UInt32]
    let blue: [UInt32]
    let luma: [UInt32]
    let total: UInt64
    /// True when the scan skipped pixels (the live panel's stride). The
    /// shape is the same; the counts are a sample of it.
    let sampled: Bool

    /// From the core's flat 1024 counts — 256 red, then green, blue, luma.
    /// nil for any other length, so a mis-sized buffer can never be drawn
    /// as if it were bins.
    init?(flat: [UInt32], total: UInt64, sampled: Bool) {
        guard flat.count == 1024 else { return nil }
        red = Array(flat[0..<256])
        green = Array(flat[256..<512])
        blue = Array(flat[512..<768])
        luma = Array(flat[768..<1024])
        self.total = total
        self.sampled = sampled
    }

    /// The largest per-channel count sitting in bin 0 — pixels at or below
    /// black in at least one channel, which is what a shadow-clipping
    /// warning lights on.
    var shadowClipped: UInt32 { max(red[0], green[0], blue[0]) }

    /// The same at the top end.
    var highlightClipped: UInt32 { max(red[255], green[255], blue[255]) }

    /// The scale the plot divides by: the peak over bins 1...254 ONLY.
    ///
    /// The two end bins are reported separately (and drawn as the clipping
    /// wedges), because including them lets ONE spike — a black border, a
    /// blown sky, a poster's flat colour — flatten everything a
    /// photographer actually reads. Falls back to the full-range peak when
    /// 1...254 are all zero (a pure black-and-white image), and to 1 when
    /// even that is zero, so the division is always safe.
    var plotPeak: UInt32 {
        var peak: UInt32 = 0
        for channel in [red, green, blue, luma] {
            for bin in 1...254 where channel[bin] > peak { peak = channel[bin] }
        }
        if peak > 0 { return peak }
        for channel in [red, green, blue, luma] {
            peak = Swift.max(peak, channel[0], channel[255])
        }
        return Swift.max(peak, 1)
    }
}

/// Which pixels a histogram counts. "Selection" is a GATE on any of these,
/// not a fourth source.
/// `Equatable` so a caller can memoize the image it resolved and know at a
/// glance whether the next request asks for the same one — every payload is
/// a layer index, so the synthesized comparison is exactly right.
enum HistogramSource: Equatable {
    /// The flattened document — what the canvas shows.
    case composite
    /// One layer's canvas-space image (0 outside the layer's rect).
    case layer(Int)
    /// The composite of everything BELOW `below` — what an adjustment layer
    /// at that index actually acts on, and therefore the only thing a plot
    /// behind its Levels or Curves controls may show. The composite would
    /// already have the correction (and every layer above it) baked in, so
    /// the handles would not line up with the tones they move.
    case backdrop(below: Int)

    /// The image this source names. Canvas-sized work on `.backdrop` (a
    /// flatten) and on `.layer`, cheap on `.composite` (the editor keeps a
    /// warm projection) — resolve it on the main thread and hand the RESULT
    /// to `HistogramLoader`, which is what keeps a handle on one queue at a
    /// time, or memoize it the way the Info panel does.
    func image(in document: ImageDocument) -> RasterImage? {
        guard let doc = document.doc else { return nil }
        if case .composite = self, let warm = document.projection { return warm }
        return image(in: doc)
    }

    /// The same resolution inside a RASTER handle alone — no editor state,
    /// so the whole thing can run on a background queue with the handle
    /// captured by value, which is what a sheet's one-shot capture does.
    /// The core's documents are immutable and its two caches are behind
    /// mutexes, so a read here is safe alongside `PreviewRenderer`'s.
    func image(in doc: RasterDocument) -> RasterImage? {
        switch self {
        case .composite:
            return doc.flattened()
        case .layer(let idx):
            guard idx >= 0, idx < doc.layerCount else { return nil }
            return doc.layerCanvasImage(idx)
        case .backdrop(let below):
            // Nothing is below the bottom of the stack; the caller draws no
            // plot rather than an empty one.
            guard below >= 1, below <= doc.layerCount else { return nil }
            let tree = doc.layerTree
            var scratch = doc
            for idx in below..<doc.layerCount {
                // An ENCLOSING group — one whose subtree reaches BELOW the
                // insertion point — is skipped, because hiding a group hides
                // its whole subtree and would take the layers under the
                // boundary down with it: an adjustment layer inside a group
                // would then plot a backdrop missing the very layers it acts
                // on. Left visible, the group renders exactly the children
                // this sweep left alone, at its own opacity and mask, which
                // is the backdrop the adjustment composites over. The same
                // exception MultiLayerEdit.transformStackComposites makes for
                // its `below` plate, and it covers both callers: the new
                // layer's insertion point and an existing one's own index.
                guard tree.subtree(of: idx).lowerBound >= below else { continue }
                scratch = scratch.hidingLayer(idx)
            }
            return scratch.flattened()
        }
    }
}

enum Histogram {
    /// The bins of one image, gated by `selection` (a canvas-sized coverage
    /// buffer) when given. Canvas-sized work: never call it on the main
    /// thread for a live panel — that is what `HistogramLoader` is for —
    /// and never per slider tick or per mouse-moved
    /// (`SliderSheetController`'s standing warning about canvas-sized reads
    /// ahead of a debounce).
    static func of(_ image: RasterImage, selection: [UInt8]?, stride: Int) -> HistogramBins? {
        let step = Swift.max(1, stride)
        guard let scan = image.histogram(mask: selection, stride: step) else { return nil }
        return HistogramBins(flat: scan.bins, total: scan.total, sampled: step > 1)
    }

    /// The bins for a SOURCE of `document`. Resolving the source is itself
    /// canvas-sized on `.backdrop` and `.layer`, so this whole call belongs
    /// off the main thread for anything live.
    static func of(
        _ document: ImageDocument, source: HistogramSource, selection: [UInt8]?, stride: Int
    ) -> HistogramBins? {
        guard let image = source.image(in: document) else { return nil }
        return of(image, selection: selection, stride: stride)
    }

    /// Which pixels a dialog's plot counts, as VALUES: the layer being
    /// filtered for a destructive sheet, and the BACKDROP BELOW the layer
    /// for an adjustment-layer sheet — `.edit` the layer's own index,
    /// `.create` the index the new layer will be inserted at. `.create`
    /// also gates on the selection it captured, because that is exactly
    /// where the new layer's mask will let the adjustment act.
    ///
    /// Decided on the main thread because it reads the editor's active
    /// layer; nothing it returns is a handle, so the scan it names runs on
    /// a background queue.
    static func sheetPlan(
        _ document: ImageDocument, mode: AdjustmentSheetMode, destructiveLayer: Int?
    ) -> (source: HistogramSource, selection: [UInt8]?) {
        switch mode {
        case .destructive:
            return (.layer(destructiveLayer ?? document.activeLayerIndex), nil)
        case .create(let selection):
            return (.backdrop(below: document.activeLayerIndex + 1), selection)
        case .edit(let layer, _):
            return (.backdrop(below: layer), nil)
        }
    }

    /// The bins a dialog plots behind its controls, captured ONCE at sheet
    /// open at stride 1 — but OFF the main thread, `apply` landing back on
    /// it when they arrive (the plot simply draws empty until then).
    ///
    /// Doing it inline in a controller's `init` is what this exists to
    /// stop: `.layer` is a canvas-sized `rz_doc_layer_canvas_image` and
    /// `.backdrop` a clone per layer above the target plus a full flatten,
    /// so on a 100 MP document Levels froze the UI for about half a second
    /// before the sheet appeared and Curves on an adjustment layer for
    /// about one. The sheet these replaced did no canvas-sized work at
    /// open, so an inline capture was a regression, not a cost of the
    /// feature.
    ///
    /// The loader is a one-shot here rather than a debouncer — it is used
    /// instead of a bare `DispatchQueue` because it already owns the hop
    /// out and the hop back — and it is parked in `inFlight` for the single
    /// round trip. That is deliberate: it means a caller needs no stored
    /// property, which is what keeps the two callers inside `Sheets.swift`
    /// (frozen) down to one wiring line each.
    static func loadForSheet(
        _ document: ImageDocument, mode: AdjustmentSheetMode, destructiveLayer: Int?,
        then apply: @escaping (HistogramBins?) -> Void
    ) {
        guard let doc = document.doc else {
            apply(nil)
            return
        }
        let plan = sheetPlan(document, mode: mode, destructiveLayer: destructiveLayer)
        let loader = HistogramLoader()
        nextTicket += 1
        let ticket = nextTicket
        inFlight[ticket] = loader
        // The closure captures the TICKET, not the loader: capturing the
        // loader would be a cycle through its own `onBins`, and the parking
        // slot is what keeps it alive instead.
        loader.onBins = { bins in
            apply(bins)
            inFlight.removeValue(forKey: ticket)
        }
        loader.request {
            guard let image = plan.source.image(in: doc) else { return nil }
            return of(image, selection: plan.selection, stride: 1)
        }
    }

    /// One-shot sheet captures with a delivery still in flight, held only
    /// for the hop out and back. Main-thread only, like everything else on
    /// this side; `HistogramLoader` always delivers exactly once, so a slot
    /// is never left behind.
    private static var inFlight: [Int: HistogramLoader] = [:]
    private static var nextTicket = 0

    /// The stride the LIVE panel scans at: enough pixels for a stable shape
    /// (~4 M) and no more, so a 24 MP document does not re-scan itself on
    /// every brush tick.
    ///
    /// It is then bumped upward until it shares no factor with the row
    /// length: a stride that divides the width lands on the same columns in
    /// every row forever, which on anything with vertical structure — a
    /// gradient, a border, a picket fence — samples a biased slice of the
    /// image rather than a thinner copy of it.
    static func liveStride(pixels: Int, width: Int) -> Int {
        guard pixels > 4_000_000, width > 0 else { return 1 }
        var stride = Swift.max(1, pixels / 4_000_000)
        while stride > 1 && gcd(stride, width) != 1 { stride += 1 }
        return stride
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}

/// Debounced, coalescing background scanner for the LIVE panel: the same
/// shape as `PreviewRenderer` (Sheets.swift) — which is frozen and typed to
/// `CGImage`, so it cannot be reused directly — hopping back to main with
/// the bins.
///
/// Capture the `RasterImage` and the mask bytes by VALUE in the closure
/// (both are immutable, and `CanvasSelection` is a struct), never the
/// document: the handle must be touched by one queue at a time, and the
/// document's is the main thread's.
final class HistogramLoader {
    private let queue = DispatchQueue(label: "com.rasterize.histogram")
    private var pending: (() -> HistogramBins?)?
    private var isLoading = false
    private var debounce: DispatchWorkItem?

    var onBins: ((HistogramBins?) -> Void)?

    func request(_ compute: @escaping () -> HistogramBins?) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pending = compute
            self.drain()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func cancel() {
        debounce?.cancel()
        debounce = nil
        pending = nil
        onBins = nil
        // Wait out any in-flight scan, exactly as PreviewRenderer does: Rz
        // handles are not thread-safe and the caller may touch the same one
        // the moment this returns. The queue only hops back to main
        // asynchronously, so this cannot deadlock.
        queue.sync {}
    }

    private func drain() {
        guard !isLoading, let compute = pending else { return }
        pending = nil
        isLoading = true
        queue.async { [weak self] in
            let bins = compute()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                self.onBins?(bins)
                self.drain()
            }
        }
    }
}
