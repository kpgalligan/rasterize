import AppKit

/// The stamped pipeline's tip: the options bar's Hardness, Flow, Spacing,
/// Angle and Roundness resolved to the fractions SoftBrush speaks, latched
/// once per stroke. `flow` is each dab's deposit (buildup within one
/// stroke; the stroke's Opacity still caps exactly once, where the overlay
/// is consumed); `spacingPercent` is dab spacing as a percentage of the
/// diameter; `roundness` compresses the dab's minor axis and
/// `angleDegrees` rotates it counter-clockwise on screen.
struct BrushTip: Equatable {
    static let defaultSpacingPercent: CGFloat = 25

    var hardness: CGFloat = 1
    var flow: CGFloat = 1
    var spacingPercent: CGFloat = defaultSpacingPercent
    var angleDegrees: CGFloat = 0
    var roundness: CGFloat = 1
}

/// The soft-brush dab engine behind the paint tools' Hardness option, shared
/// by the interactive stroke pipeline (ImageCanvasView) and the agent's
/// stroke tools (paint_stroke / erase / clone_stamp / dodge_burn) so a
/// stroke rasterized either way lands the same pixels.
///
/// A hard stroke (hardness 100 with a default tip) keeps the classic path:
/// one round-capped stroked path, uniform alpha. Everything else STAMPS —
/// dabs along the stroke whose alpha holds at 1 out to `hardness` of the
/// radius and smoothsteps to 0 at the rim, spaced by the tip's Spacing,
/// squashed by Roundness, rotated by Angle, each dab deposited at the
/// tip's Flow. Dabs composite source-over, so a stroke that crosses itself
/// accumulates toward opaque — flow/airbrush buildup, deliberate and
/// shared by both pipelines.
enum SoftBrush {
    /// Whether a stroke of this hardness (0–1) and diameter stamps soft
    /// dabs. At-or-near 100% keeps the hard path-stroke pipeline, and so
    /// does the size-1 pixel brush (whose whole point is hard pixels).
    static func isSoft(hardness: CGFloat, size: CGFloat) -> Bool {
        hardness < 0.995 && size > 1
    }

    /// Whether a stroke with this tip stamps dabs rather than stroking one
    /// hard path. Softness is one trigger among four: sub-100 flow needs
    /// per-dab deposit, spacing WIDER than the default is a dab rhythm the
    /// path cannot draw, and a squashed tip needs a footprint a round pen
    /// hasn't got. Spacing at or below the default keeps the (smoother)
    /// path pipeline for an otherwise-hard tip: dabs that dense merge into
    /// a solid stroke anyway, and the path draws that stroke without
    /// scalloping — which also keeps every stored pre-feature spacing
    /// value rendering exactly as it always did. The size-1 pixel brush
    /// never stamps.
    static func isStamped(tip: BrushTip, size: CGFloat) -> Bool {
        guard size > 1 else { return false }
        return tip.hardness < 0.995 || tip.flow < 0.995
            || tip.spacingPercent > BrushTip.defaultSpacingPercent + 0.5
            || tip.roundness < 0.995
    }

    /// Dab spacing for a brush diameter at the default 25% rhythm (the
    /// clone stamp's rule), floored at 1 px.
    static func spacing(for size: CGFloat) -> CGFloat {
        spacing(for: size, percent: BrushTip.defaultSpacingPercent)
    }

    /// Dab spacing as a percentage of the diameter — the tip's Spacing
    /// option — floored at 1 px so a dense rhythm can never stall the walk.
    static func spacing(for size: CGFloat, percent: CGFloat) -> CGFloat {
        max(size * min(max(percent, 1), 200) / 100, 1)
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
            let stops = gradientStops(hardness: rimCapped(hardness, diameter: diameter))
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
        let capped = rimCapped(hardness, diameter: diameter)
        for y in 0..<side {
            for x in 0..<side {
                let dx = CGFloat(x) + 0.5 - radius
                let dy = CGFloat(y) + 0.5 - radius
                let t = min(hypot(dx, dy) / radius, 1)
                gray[y * side + x] = UInt8((falloff(t, hardness: capped) * 255).rounded())
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

    // MARK: - Stamping through the tip

    /// Stamps `dab` centered at `point`, `diameter` px across, through the
    /// tip's rotation and roundness. A round tip takes the plain fast path.
    /// Both pipelines' overlay contexts are flipped (row 0 = top), so the
    /// negated angle keeps a positive Angle counter-clockwise on screen.
    static func stamp(
        _ dab: CGImage, in context: CGContext, at point: CGPoint,
        diameter: CGFloat, tip: BrushTip
    ) {
        let rect = CGRect(
            x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter)
        guard tip.roundness < 0.995 else {
            context.draw(dab, in: rect.offsetBy(dx: point.x, dy: point.y))
            return
        }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: -tip.angleDegrees * .pi / 180)
        context.scaleBy(x: 1, y: max(tip.roundness, 0.01))
        context.draw(dab, in: rect)
        context.restoreGState()
    }

    /// Clips the context to ONE dab footprint at `point` for image-carrying
    /// dabs (the clone stamp): the gray falloff `mask`, or a hard ellipse
    /// when nil, pushed through the tip's rotation and roundness. Only the
    /// CLIP survives the call — the CTM is put back — so the caller draws
    /// its image in untransformed coordinates. The caller's save/restore
    /// pops the clip.
    static func clipDab(
        in context: CGContext, at point: CGPoint, diameter: CGFloat,
        tip: BrushTip, mask: CGImage?
    ) {
        let roundness = max(tip.roundness, 0.01)
        let rect = CGRect(
            x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter)
        guard roundness < 0.995 else {
            let plain = rect.offsetBy(dx: point.x, dy: point.y)
            if let mask = mask {
                context.clip(to: plain, mask: mask)
            } else {
                context.addEllipse(in: plain)
                context.clip()
            }
            return
        }
        let transform = CGAffineTransform(translationX: point.x, y: point.y)
            .rotated(by: -tip.angleDegrees * .pi / 180)
            .scaledBy(x: 1, y: roundness)
        context.concatenate(transform)
        if let mask = mask {
            context.clip(to: rect, mask: mask)
        } else {
            context.addEllipse(in: rect)
            context.clip()
        }
        context.concatenate(transform.inverted())
    }

    // MARK: - Internals

    /// Stamped dabs cap hardness so the rim keeps an anti-aliased band
    /// about 1 px wide (a quarter of the radius for tiny dabs): a true
    /// hardness-1 dab would alias, its falloff band thinner than a pixel.
    /// Genuinely soft dabs sit below the cap and are untouched.
    private static func rimCapped(_ hardness: CGFloat, diameter: CGFloat) -> CGFloat {
        min(max(hardness, 0), 1 - min(2 / max(diameter, 2), 0.25))
    }

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
