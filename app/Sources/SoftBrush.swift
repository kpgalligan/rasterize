import AppKit

/// The soft-brush dab engine behind the paint tools' Hardness option, shared
/// by the interactive stroke pipeline (ImageCanvasView) and the agent's
/// stroke tools (paint_stroke / erase / clone_stamp / dodge_burn) so a
/// stroke rasterized either way lands the same pixels.
///
/// A hard stroke (hardness 100) keeps the classic path: one round-capped
/// stroked path, uniform alpha. Below that, the stroke becomes STAMPED —
/// round dabs at quarter-diameter spacing whose alpha holds at 1 out to
/// `hardness` of the radius and smoothsteps to 0 at the rim. Dabs composite
/// source-over, so a stroke that crosses itself accumulates in its soft
/// fringe — flow-style airbrush behavior, deliberate and shared by both
/// pipelines.
enum SoftBrush {
    /// Whether a stroke of this hardness (0–1) and diameter stamps soft
    /// dabs. At-or-near 100% keeps the hard path-stroke pipeline, and so
    /// does the size-1 pixel brush (whose whole point is hard pixels).
    static func isSoft(hardness: CGFloat, size: CGFloat) -> Bool {
        hardness < 0.995 && size > 1
    }

    /// Dab spacing for a brush diameter: a quarter of the diameter (the
    /// clone stamp's rule), floored at 1 px.
    static func spacing(for size: CGFloat) -> CGFloat {
        max(size / 4, 1)
    }

    /// The dab's alpha at normalized distance `t` (0 center, 1 rim) for
    /// `hardness` in 0–1: solid out to `hardness`, smoothstep down to 0 at
    /// the rim. Monotone non-increasing in `t` for every hardness.
    static func falloff(_ t: CGFloat, hardness: CGFloat) -> CGFloat {
        let h = min(max(hardness, 0), 1)
        guard t > h else { return 1 }
        guard t < 1, h < 1 else { return 0 }
        let s = (t - h) / (1 - h)
        return 1 - s * s * (3 - 2 * s)
    }

    /// A colored dab to stamp with `context.draw`: `diameter` px across,
    /// `color`'s own alpha at the core falling off per `falloff`. The
    /// stroke's opacity rides in via the color's alpha exactly as it does
    /// for a hard stroke. nil only if CoreGraphics cannot build the bitmap.
    static func dab(color: NSColor, diameter: CGFloat, hardness: CGFloat) -> CGImage? {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let baseAlpha = srgb.alphaComponent
        return dabImage(diameter: diameter) { context, radius in
            let stops = gradientStops(hardness: hardness)
            let colors = stops.map {
                CGColor(
                    srgbRed: srgb.redComponent, green: srgb.greenComponent,
                    blue: srgb.blueComponent, alpha: baseAlpha * $0.alpha)
            }
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: colors as CFArray, locations: stops.map { $0.location })
            else { return }
            let center = CGPoint(x: radius, y: radius)
            context.drawRadialGradient(
                gradient, startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius, options: [])
        }
    }

    /// A DeviceGray clip mask for dabs that carry an IMAGE rather than a
    /// color (the clone stamp): white at the core, falling to black at the
    /// rim. `CGContext.clip(to:mask:)` with a plain gray image passes paint
    /// where the mask is white (verified empirically — an image MASK is the
    /// inverse convention).
    static func dabMask(diameter: CGFloat, hardness: CGFloat) -> CGImage? {
        let side = max(Int(ceil(diameter)), 1)
        var gray = [UInt8](repeating: 0, count: side * side)
        let radius = CGFloat(side) / 2
        for y in 0..<side {
            for x in 0..<side {
                let dx = CGFloat(x) + 0.5 - radius
                let dy = CGFloat(y) + 0.5 - radius
                let t = min(hypot(dx, dy) / radius, 1)
                gray[y * side + x] = UInt8((falloff(t, hardness: hardness) * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }

    /// The most dabs one stroke will ever stamp: a backstop, not a tuning
    /// knob. The callers' coordinate validation keeps real strokes far
    /// below it; a stroke that hits it truncates instead of hanging the
    /// main thread with per-dab drawing.
    static let maxStampsPerStroke = 50_000

    /// Stamp centers along a polyline at `spacing`: the first point always
    /// stamps (a click leaves a dab), then every `spacing` px of arc length.
    /// The leftover distance carries across vertices, so dab rhythm does not
    /// reset at every segment — the interactive walk's behavior. Capped at
    /// `maxStampsPerStroke`.
    static func stampCenters(along points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var centers = [first]
        var anchor = first
        for point in points.dropFirst() {
            var distance = hypot(point.x - anchor.x, point.y - anchor.y)
            while distance >= spacing {
                guard centers.count < maxStampsPerStroke else { return centers }
                let step = spacing / distance
                anchor = CGPoint(
                    x: anchor.x + (point.x - anchor.x) * step,
                    y: anchor.y + (point.y - anchor.y) * step)
                centers.append(anchor)
                distance = hypot(point.x - anchor.x, point.y - anchor.y)
            }
        }
        return centers
    }

    // MARK: - Internals

    /// Locations/alphas approximating `falloff` for CGGradient's linear
    /// interpolation: the two exact knees plus fixed samples across the
    /// falloff band.
    private static func gradientStops(
        hardness: CGFloat
    ) -> [(location: CGFloat, alpha: CGFloat)] {
        let h = min(max(hardness, 0), 1)
        var stops: [(CGFloat, CGFloat)] = [(0, 1), (h, 1)]
        let samples = 8
        for i in 1...samples {
            let t = h + (1 - h) * CGFloat(i) / CGFloat(samples)
            stops.append((t, falloff(t, hardness: h)))
        }
        return stops.map { (location: $0.0, alpha: $0.1) }
    }

    /// A premultiplied-sRGB square bitmap `diameter` px across handed to
    /// `draw` with its radius; nil if the context cannot be made.
    private static func dabImage(
        diameter: CGFloat, draw: (CGContext, CGFloat) -> Void
    ) -> CGImage? {
        let side = max(Int(ceil(diameter)), 1)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(context, CGFloat(side) / 2)
        return context.makeImage()
    }
}
