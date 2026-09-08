import AppKit

/// The ONE histogram plot: per-channel or luminosity, with a clipping wedge
/// at each end. Used by the Info panel, the Levels sheets and — through
/// `drawHistogram` — the Curves editor, so a tone the user reads in one
/// place is the same picture in the others.
final class HistogramView: NSView {
    /// Which counts the plot shows. `.rgb` overlays all three channels;
    /// `.luminosity` is the Rec. 709 luma the core bins alongside them.
    enum Display: Int, CaseIterable {
        case luminosity
        case rgb
        case red
        case green
        case blue

        var displayName: String {
            switch self {
            case .luminosity: return "Luminosity"
            case .rgb: return "RGB"
            case .red: return "Red"
            case .green: return "Green"
            case .blue: return "Blue"
            }
        }
    }

    var bins: HistogramBins? {
        didSet { needsDisplay = true }
    }
    var display: Display = .luminosity {
        didSet { needsDisplay = true }
    }

    /// 256 bins at 1 pt each, so a bar is a bar and nothing is resampled.
    override var intrinsicContentSize: NSSize { NSSize(width: 256, height: 72) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HistogramView does not support NSCoder")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        guard rect.width > 0, rect.height > 0 else { return }
        DS.canvasVoid.setFill()
        NSBezierPath(rect: rect).fill()
        if let bins = bins {
            drawHistogram(bins, display: display, in: rect.insetBy(dx: 1, dy: 1))
        }
        let frame = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        DS.border.setStroke()
        frame.stroke()
    }
}

/// The plot itself, so the Curves editor draws the same picture inside its
/// own `plotRect` without owning a subview.
///
/// Bars scale by `bins.plotPeak` — the peak over bins 1...254, so one spike
/// at pure black or pure white cannot flatten everything between them — and
/// are clamped to the rect. The two end bins are instead reported by the
/// clipping wedges at the top corners, which light when at least 0.1 % of
/// the counted pixels sit there: the same "enough pixels to matter"
/// threshold Auto Tone clips by, so the warning and the automatic
/// correction agree about what counts as clipped.
///
/// Nothing here fills a background: the caller owns its ground (the view
/// below, and `CurveEditorView`'s own `DS.canvasVoid` fill).
func drawHistogram(_ bins: HistogramBins, display: HistogramView.Display, in rect: NSRect) {
    guard rect.width > 0, rect.height > 0 else { return }
    let peak = CGFloat(bins.plotPeak)

    func bars(_ counts: [UInt32], _ color: NSColor) {
        let path = NSBezierPath()
        let step = rect.width / 256
        for bin in 0..<256 {
            let height = min(CGFloat(counts[bin]) / peak, 1) * rect.height
            guard height > 0 else { continue }
            path.appendRect(
                NSRect(
                    x: rect.minX + CGFloat(bin) * step, y: rect.minY,
                    width: max(step, 1), height: height))
        }
        color.setFill()
        path.fill()
    }

    switch display {
    case .luminosity:
        bars(bins.luma, DS.textFaint.withAlphaComponent(0.75))
    case .rgb:
        // Overlaid at partial alpha rather than stacked: where the three
        // agree the bar reads neutral, which is what "this tone is grey"
        // looks like in every editor's RGB histogram.
        bars(bins.red, NSColor.systemRed.withAlphaComponent(0.45))
        bars(bins.green, NSColor.systemGreen.withAlphaComponent(0.45))
        bars(bins.blue, NSColor.systemBlue.withAlphaComponent(0.45))
    case .red:
        bars(bins.red, CurveChannel.red.strokeColor.withAlphaComponent(0.7))
    case .green:
        bars(bins.green, CurveChannel.green.strokeColor.withAlphaComponent(0.7))
    case .blue:
        bars(bins.blue, CurveChannel.blue.strokeColor.withAlphaComponent(0.7))
    }

    let threshold = Double(bins.total) * 0.001
    let side: CGFloat = 7
    func wedge(atLeft left: Bool) {
        let path = NSBezierPath()
        let x = left ? rect.minX : rect.maxX
        let dx: CGFloat = left ? side : -side
        path.move(to: NSPoint(x: x, y: rect.maxY))
        path.line(to: NSPoint(x: x + dx, y: rect.maxY))
        path.line(to: NSPoint(x: x, y: rect.maxY - side))
        path.close()
        NSColor.systemOrange.withAlphaComponent(0.9).setFill()
        path.fill()
    }
    if bins.total > 0, Double(bins.shadowClipped) > threshold { wedge(atLeft: true) }
    if bins.total > 0, Double(bins.highlightClipped) > threshold { wedge(atLeft: false) }
}
