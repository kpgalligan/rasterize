import AppKit

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
    /// Grayscale CGImages of the wand mask and its inverse (alpha sources
    /// for clipping and outside-dimming); nil for geometric shapes.
    let maskImage: CGImage?
    let inverseMaskImage: CGImage?

    /// nil when the selection would be empty.
    init?(shape: Shape, canvasWidth: Int, canvasHeight: Int) {
        guard canvasWidth > 0, canvasHeight > 0 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        var maskImage: CGImage? = nil
        var inverseMaskImage: CGImage? = nil
        let bounds: CGRect
        switch shape {
        case .rect(let rect), .ellipse(let rect):
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
            for y in 0..<canvasHeight {
                let row = y * canvasWidth
                for x in 0..<canvasWidth where mask[row + x] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            maskImage = Self.grayImage(mask, canvasWidth, canvasHeight)
            inverseMaskImage = Self.grayImage(
                mask.map { 255 - $0 }, canvasWidth, canvasHeight)
        }
        guard !bounds.isEmpty, bounds.width >= 1, bounds.height >= 1 else { return nil }
        self.shape = shape
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.bounds = bounds
        self.maskImage = maskImage
        self.inverseMaskImage = inverseMaskImage
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
