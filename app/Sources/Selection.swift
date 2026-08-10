import AppKit

/// How a newly made selection combines with the existing one (Photoshop
/// modifier conventions: Shift = add, Option = subtract, both = intersect).
enum SelectionCombineMode {
    case replace
    case add
    case subtract
    case intersect
}

/// A selection region on the canvas: exact geometry for marquee drawing
/// and CG clipping, plus a coverage mask for the core's region operations
/// (fill, gradient) and for mask-shaped (magic wand) selections.
///
/// Coverage masks are canvas-sized u8 buffers, row 0 = top: 0 outside,
/// 255 fully inside, intermediate values at anti-aliased edges.
struct CanvasSelection {
    enum Shape {
        case rect(CGRect)
        case ellipse(CGRect)
        case polygon([CGPoint])
        /// Canvas-sized coverage bytes (magic wand).
        case mask([UInt8])
    }

    let shape: Shape
    let canvasWidth: Int
    let canvasHeight: Int
    /// Integral bounding box of the selected region, clamped to the canvas.
    let bounds: CGRect
    /// True when every canvas pixel is fully covered — inverting such a
    /// selection selects nothing. Exact for masks and rects, conservative
    /// (false) for ellipses and polygons. The empty fact needs no cache:
    /// a CanvasSelection is never empty (init returns nil instead).
    let isFullCanvas: Bool
    /// Grayscale CGImages of the wand mask and its inverse (alpha sources
    /// for clipping and outside-dimming); nil for geometric shapes.
    let maskImage: CGImage?
    let inverseMaskImage: CGImage?
    /// Traced outline of a mask selection (marching squares at coverage
    /// >= 128, holes included), computed once at creation; nil for
    /// geometric shapes.
    let maskContour: NSBezierPath?

    /// nil when the selection would be empty.
    init?(shape: Shape, canvasWidth: Int, canvasHeight: Int) {
        guard canvasWidth > 0, canvasHeight > 0 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        var maskImage: CGImage? = nil
        var inverseMaskImage: CGImage? = nil
        var maskContour: NSBezierPath? = nil
        var isFullCanvas = false
        let bounds: CGRect
        switch shape {
        case .rect(let rect):
            bounds = rect.integral.intersection(canvas)
            isFullCanvas = rect.contains(canvas)
        case .ellipse(let rect):
            bounds = rect.integral.intersection(canvas)
        case .polygon(let points):
            guard points.count >= 3 else { return nil }
            var box = CGRect(origin: points[0], size: .zero)
            for point in points.dropFirst() {
                box = box.union(CGRect(origin: point, size: .zero))
            }
            bounds = box.integral.intersection(canvas)
        case .mask(let mask):
            guard mask.count == canvasWidth * canvasHeight else { return nil }
            var minX = canvasWidth
            var minY = canvasHeight
            var maxX = -1
            var maxY = -1
            var full = true
            for y in 0..<canvasHeight {
                let row = y * canvasWidth
                for x in 0..<canvasWidth {
                    let value = mask[row + x]
                    if value > 0 {
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                    if value < 255 { full = false }
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            isFullCanvas = full
            maskImage = Self.grayImage(mask, canvasWidth, canvasHeight)
            inverseMaskImage = Self.grayImage(
                mask.map { 255 - $0 }, canvasWidth, canvasHeight)
            maskContour = Self.contourPath(mask, canvasWidth, canvasHeight, bounds: bounds)
        }
        guard !bounds.isEmpty, bounds.width >= 1, bounds.height >= 1 else { return nil }
        self.shape = shape
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.bounds = bounds
        self.isFullCanvas = isFullCanvas
        self.maskImage = maskImage
        self.inverseMaskImage = inverseMaskImage
        self.maskContour = maskContour
    }

    /// Exact outline for geometric shapes; nil for mask selections.
    var path: NSBezierPath? {
        switch shape {
        case .rect(let rect):
            return NSBezierPath(rect: rect)
        case .ellipse(let rect):
            return NSBezierPath(ovalIn: rect)
        case .polygon(let points):
            let path = NSBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.line(to: point)
            }
            path.close()
            return path
        case .mask:
            return nil
        }
    }

    /// Outline for the dashed marching-ants stroke: the exact path for
    /// geometric shapes, the traced contour for mask selections.
    var marqueePath: NSBezierPath? {
        path ?? maskContour
    }

    /// Set algebra over canvas-sized coverage masks. `replace` returns the
    /// new selection as-is (keeping its geometric kind); the other modes
    /// rasterize both operands per-byte — add max(a, b), subtract
    /// min(a, 255 − b), intersect min(a, b) — into a mask-kind selection.
    /// With no existing selection, add behaves as replace while subtract
    /// and intersect select nothing. nil means deselect.
    static func combine(
        _ existing: CanvasSelection?, with new: CanvasSelection, mode: SelectionCombineMode
    ) -> CanvasSelection? {
        guard mode != .replace else { return new }
        guard let existing = existing,
            existing.canvasWidth == new.canvasWidth,
            existing.canvasHeight == new.canvasHeight
        else {
            return mode == .add ? new : nil
        }
        var a = existing.maskBytes()
        let b = new.maskBytes()
        switch mode {
        case .replace, .add:
            for i in a.indices { a[i] = max(a[i], b[i]) }
        case .subtract:
            for i in a.indices { a[i] = min(a[i], 255 - b[i]) }
        case .intersect:
            for i in a.indices { a[i] = min(a[i], b[i]) }
        }
        return CanvasSelection(
            shape: .mask(a), canvasWidth: new.canvasWidth, canvasHeight: new.canvasHeight)
    }

    /// The selection's complement over the full canvas, per-byte 255 − a
    /// (nil — deselect — when the selection already covers everything).
    func inverted() -> CanvasSelection? {
        guard !isFullCanvas else { return nil }
        let bytes = maskBytes().map { 255 - $0 }
        return CanvasSelection(
            shape: .mask(bytes), canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    /// Gaussian-feathers the selection's coverage into a soft-edged
    /// mask-kind selection (nil when nothing remains, or on an invalid
    /// radius).
    func feathered(by radius: Double) -> CanvasSelection? {
        var bytes = maskBytes()
        guard
            RasterSelection.featherMask(
                &bytes, width: canvasWidth, height: canvasHeight, radius: radius)
        else { return nil }
        return CanvasSelection(
            shape: .mask(bytes), canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    /// Canvas-sized coverage bytes: geometric shapes rasterize with
    /// anti-aliased edges; wand masks return their stored bytes.
    func maskBytes() -> [UInt8] {
        if case .mask(let mask) = shape {
            return mask
        }
        var bytes = [UInt8](repeating: 0, count: canvasWidth * canvasHeight)
        guard let cgPath = path?.cgPathCompat else { return bytes }
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: canvasWidth, height: canvasHeight,
                    bitsPerComponent: 8, bytesPerRow: canvasWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            // Flip so byte row 0 is the canvas top row; white = selected.
            context.translateBy(x: 0, y: CGFloat(canvasHeight))
            context.scaleBy(x: 1, y: -1)
            context.addPath(cgPath)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
        }
        return bytes
    }

    /// Clips `context` — whose coordinates are canvas top-left-origin
    /// (flipped) — to the selected region.
    func clip(_ context: CGContext) {
        if let cgPath = path?.cgPathCompat {
            context.addPath(cgPath)
            context.clip()
            return
        }
        clipToMask(context, maskImage)
    }

    /// Clips to the INVERSE of the selection (for dimming the outside of
    /// mask-shaped selections).
    func clipOutside(_ context: CGContext) {
        clipToMask(context, inverseMaskImage)
    }

    /// clip(to:mask:) places the image through the CTM, which is flipped
    /// here — un-flip around the call; the clip region itself survives in
    /// device space.
    private func clipToMask(_ context: CGContext, _ mask: CGImage?) {
        guard let mask = mask else { return }
        let height = CGFloat(canvasHeight)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.clip(
            to: CGRect(x: 0, y: 0, width: CGFloat(canvasWidth), height: height), mask: mask)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -height)
    }

    /// Marching-squares contour of a coverage mask at threshold >= 128:
    /// every border between a covered and an uncovered pixel contributes a
    /// directed unit edge along the pixel lattice (covered side on the
    /// left, y down), and the edges link head-to-tail into closed loops —
    /// holes included. Collinear runs collapse, so the path size tracks
    /// the outline's corner count, not its length.
    private static func contourPath(
        _ mask: [UInt8], _ width: Int, _ height: Int, bounds: CGRect
    ) -> NSBezierPath? {
        let x0 = max(Int(bounds.minX), 0)
        let y0 = max(Int(bounds.minY), 0)
        let x1 = min(Int(bounds.maxX), width)
        let y1 = min(Int(bounds.maxY), height)
        func covered(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && mask[y * width + x] >= 128
        }
        // Lattice corner (x, y) encodes as y * (width + 1) + x. Each corner
        // starts at most two edges (only where covered pixels touch
        // diagonally), so a pair with -1 = unused suffices.
        let stride = width + 1
        var edges: [Int: (Int, Int)] = [:]
        func addEdge(_ start: Int, _ end: Int) {
            if let first = edges[start]?.0 {
                edges[start] = (first, end)
            } else {
                edges[start] = (end, -1)
            }
        }
        for y in y0..<y1 {
            for x in x0..<x1 where covered(x, y) {
                let corner = y * stride + x
                if !covered(x, y - 1) { addEdge(corner, corner + 1) }
                if !covered(x + 1, y) { addEdge(corner + 1, corner + 1 + stride) }
                if !covered(x, y + 1) { addEdge(corner + 1 + stride, corner + stride) }
                if !covered(x - 1, y) { addEdge(corner + stride, corner) }
            }
        }
        guard !edges.isEmpty else { return nil }

        // Corner-index delta of the clockwise turn from a travel delta
        // (+1 →, +stride ↓, -1 ←, -stride ↑). Where two covered pixels
        // touch diagonally a corner has two outgoing edges; taking the
        // clockwise turn keeps the two regions' outlines separate loops.
        func clockwise(_ delta: Int) -> Int {
            switch delta {
            case 1: return stride
            case stride: return -1
            case -1: return -stride
            default: return 1
            }
        }
        func takeEdge(from corner: Int, incoming: Int?) -> Int? {
            guard let (first, second) = edges[corner] else { return nil }
            guard second >= 0 else {
                edges[corner] = nil
                return first
            }
            let preferred = incoming.map { corner + clockwise($0) }
            if second == preferred {
                edges[corner] = (first, -1)
                return second
            }
            edges[corner] = (second, -1)
            return first
        }
        func point(_ corner: Int) -> CGPoint {
            CGPoint(x: CGFloat(corner % stride), y: CGFloat(corner / stride))
        }

        let path = NSBezierPath()
        for start in edges.keys.sorted() {
            // A diagonal-touch corner starts two loops; drain them both.
            while edges[start] != nil {
                var corner = start
                var incoming: Int? = nil
                var began = false
                while let next = takeEdge(from: corner, incoming: incoming) {
                    let delta = next - corner
                    if delta != incoming {
                        // Direction change: emit a vertex (collinear steps
                        // merge into one segment).
                        if began {
                            path.line(to: point(corner))
                        } else {
                            path.move(to: point(corner))
                            began = true
                        }
                    }
                    incoming = delta
                    corner = next
                    if corner == start { break }
                }
                if began { path.close() }
            }
        }
        return path.isEmpty ? nil : path
    }

    private static func grayImage(_ bytes: [UInt8], _ width: Int, _ height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }
}

extension NSBezierPath {
    /// CGPath bridge for macOS 13 (NSBezierPath.cgPath is macOS 14+).
    var cgPathCompat: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
