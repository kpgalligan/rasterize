import AppKit

/// A single printed page: the document's flattened composite, drawn once.
///
/// It draws a CGImage already tagged with the document's profile, so the
/// print system does the printer transform — the same division of labour
/// the canvas uses for the display transform.
final class PrintCanvasView: NSView {
    private let image: CGImage
    private let imageFrame: NSRect

    /// `pageSize` is the whole printable area and `imageFrame` is where the
    /// picture sits inside it.
    ///
    /// The view fills the page rather than being the picture's own size so
    /// that AppKit's `.fit` pagination has nothing left to scale: the
    /// fit-to-page rule (scale DOWN only, never up) is decided once, in
    /// `PrintSize.fitted`, and cannot be re-applied on top of itself.
    init(image: CGImage, pageSize: NSSize, imageFrame: NSRect) {
        self.image = image
        self.imageFrame = imageFrame
        super.init(frame: NSRect(origin: .zero, size: pageSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PrintCanvasView does not support NSCoder")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // The picture is usually scaled down to the page, and high-quality
        // resampling is the whole point of printing at the document's ppi.
        context.interpolationQuality = .high
        // The view is NOT flipped, so it shares CoreGraphics' orientation and
        // `draw(_:in:)` already puts row 0 of the image at the top of the
        // rect. Transparent pixels are simply left unpainted, which on paper
        // is white — the same answer compositing over white would give.
        context.draw(image, in: imageFrame)
        context.restoreGState()
    }
}

extension ImageDocument {
    /// File > Print: the flattened composite at the document's own print
    /// resolution — `pixels / ppi × 72` points per axis, which is why the
    /// same 1024 × 768 pixels cover 14.2 inches at 72 ppi and 3.4 inches at
    /// 300 ppi.
    ///
    /// Larger than the page, it is scaled down uniformly and centred; it is
    /// never scaled up, because enlarging would print it at a resolution the
    /// document does not have. One page, both axes.
    ///
    /// Printing is not an edit: no undo step, no dirty flag, and no MCP
    /// mirror — nothing user-visible about the document changes. Page Setup
    /// needs no code either: `NSDocument.runPageLayout(_:)` is inherited and
    /// edits this document's `printInfo`, which is what the paper size and
    /// the margins below are read from.
    override func printOperation(
        withSettings printSettings: [NSPrintInfo.AttributeKey: Any]
    ) throws -> NSPrintOperation {
        // Every save path commits an open text or transform session first;
        // printing is a read of the same composite and does the same, so
        // what prints is what the canvas shows.
        commitPendingCanvasSessions()
        guard let doc = doc,
              let composite = projection ?? doc.flattened(),
              let image = composite.makeCGImage(in: doc.colorSpace)
        else {
            throw RasterCoreError(message: "There is nothing to print.")
        }

        let info = printInfo.copy() as? NSPrintInfo ?? NSPrintInfo(dictionary: [:])
        for (key, value) in printSettings {
            // The attribute dictionary is an NSMutableDictionary keyed by the
            // raw string; the Swift `AttributeKey` wrapper does not bridge to
            // an NSString key, so unwrap each one.
            info.dictionary()[key.rawValue] = value
        }
        // One page in each direction: this is a picture, not a document that
        // continues over the fold.
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        // The picture is centred in `frame` below, inside a view that already
        // fills the content rect, so these decide nothing here; they keep
        // AppKit's own placement agreeing with ours if it lays the view out
        // against a content rect other than the one computed here.
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true

        let page = Self.printableArea(of: info)
        let printSize = PrintSize(pixels: (doc.width, doc.height), ppi: doc.resolution)
        let drawn = PrintSize.fitted(printSize.points, within: page.ink)
        let frame = NSRect(
            x: ((page.content.width - drawn.width) / 2).rounded(),
            y: ((page.content.height - drawn.height) / 2).rounded(),
            width: drawn.width, height: drawn.height)

        let operation = NSPrintOperation(
            view: PrintCanvasView(image: image, pageSize: page.content, imageFrame: frame),
            printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = displayName
        return operation
    }

    /// Where a page can take ink, in two parts.
    ///
    /// `content` is the paper less the margins Page Setup owns — the rect
    /// AppKit lays a print view out into. The view is made exactly this
    /// size, so `.fit` pagination has a scale of exactly 1: it still
    /// guarantees the single page it is set for, and it cannot enlarge the
    /// picture behind `PrintSize.fitted`'s back.
    ///
    /// `ink` is that rect capped by the printer's own imageable area, and it
    /// is what the picture is fitted into, so nothing lands in a hardware
    /// margin and is silently clipped when someone sets the margins to zero
    /// in Page Setup. A printer that reports no imageable area at all (no
    /// printer configured) contributes no cap rather than a zero one.
    ///
    /// Both are floored at one point so a nonsense page setup still yields a
    /// view AppKit can lay out.
    private static func printableArea(of info: NSPrintInfo) -> (content: NSSize, ink: NSSize) {
        let paper = info.paperSize
        let hardware = info.imageablePageBounds.size
        let content = NSSize(
            width: max(paper.width - info.leftMargin - info.rightMargin, 1),
            height: max(paper.height - info.topMargin - info.bottomMargin, 1))
        let ink = NSSize(
            width: hardware.width > 0 ? min(content.width, hardware.width) : content.width,
            height: hardware.height > 0 ? min(content.height, hardware.height) : content.height)
        return (content, ink)
    }
}
