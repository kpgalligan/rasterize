import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Renders the warped-layer half of a Free Transform preview once corner
/// offsets are live: Core Image's perspective transform pushes the session's
/// cached layer image onto the warped quad, which `CGContext`'s affine-only
/// CTM cannot express. Pure preview machinery, exactly as cheap-and-cached
/// as the affine path — the document is untouched and the core's resampler
/// still runs once, at commit. The preview renders at canvas resolution, so
/// deep zooms show it slightly soft; the committed pixels do not.
enum PerspectivePreview {
    /// One reusable rendering context — creating one per drag tick is the
    /// documented Core Image performance trap.
    private static let ciContext = CIContext()

    /// The mask bake, keyed by the two images' identities: both are built
    /// once when a session opens, so one entry covers the whole session.
    /// Main-thread only, like all drawing; dropped by `invalidate()` when
    /// the preview ends, so a finished session does not pin layer-sized
    /// images for the life of the process.
    private static var maskBake: (layer: CGImage, mask: CGImage, baked: CGImage)?

    /// Drops the cached mask bake. The canvas calls this when its transform
    /// preview clears — the cache's inputs die with the session.
    static func invalidate() {
        maskBake = nil
    }

    /// Draws `preview.layer` warped onto `preview.quad` into the canvas's
    /// flipped drawing context, honoring the session's opacity, sampler and
    /// mask. Only the part inside `visible` (the canvas bounds) is rendered:
    /// the warp is re-rendered on every tick, so the render must stay
    /// bounded by what can be seen, not by the layer's extent — the CI twin
    /// of how the affine branch's CTM draw only rasterizes the clip region.
    /// Called from `ImageCanvasView.drawTransformPreview` between the
    /// below- and above-stack composites.
    static func drawLayer(
        _ preview: ImageCanvasView.TransformPreview, in context: CGContext, visible: CGRect
    ) {
        guard let layer = preview.layer, preview.quad.count == 4,
              preview.sourceRect.width > 0, preview.sourceRect.height > 0
        else { return }
        // The mask rides the same warp as the pixels (just as the core
        // resamples both through one map), so it is baked into the layer
        // image first, in layer-local space.
        let source = preview.mask.flatMap { masked(layer, by: $0) } ?? layer

        // Work in a frame anchored at the quad's bounding box, y flipped
        // into Core Image's y-up space: ciPoint(p) = (p.x - box.minX,
        // box.maxY - p.y). CIImage(cgImage:) keeps the image visually
        // upright in that space, so its VISUAL top-left corner is the one
        // `topLeft` names.
        let box = LayerTransform.boundingExtent(of: preview.quad)
        let target = box.intersection(visible.integral)
        guard target.width >= 1, target.height >= 1,
              Double(target.width) * Double(target.height) <= LayerTransform.maxTransformPixels
        else { return }
        let ciPoint = { (p: CGPoint) in CGPoint(x: p.x - box.minX, y: box.maxY - p.y) }
        let filter = CIFilter.perspectiveTransform()
        let input = CIImage(cgImage: source)
        // Nearest previews without smoothing — the warp itself must sample
        // nearest, so the box shows the hard pixel edges the commit will
        // produce, exactly like the affine branch's `.none` quality.
        filter.inputImage = preview.interpolate ? input : input.samplingNearest()
        filter.topLeft = ciPoint(preview.quad[0])
        filter.topRight = ciPoint(preview.quad[1])
        filter.bottomRight = ciPoint(preview.quad[2])
        filter.bottomLeft = ciPoint(preview.quad[3])
        // The visible part of the warp, in the box's y-up frame.
        let ciRect = CGRect(
            x: target.minX - box.minX, y: box.maxY - target.maxY,
            width: target.width, height: target.height)
        guard let output = filter.outputImage,
              let warped = ciContext.createCGImage(output, from: ciRect)
        else { return }

        // The usual flipped-image draw into the target's canvas rect.
        context.saveGState()
        context.interpolationQuality = preview.interpolate ? .high : .none
        context.setAlpha(preview.opacity)
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(warped, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        context.restoreGState()
    }

    /// `layer` with the DeviceGray `mask` applied as alpha coverage (white
    /// shows, black hides) — the pre-warp twin of the affine path's
    /// `clip(to:mask:)`. Both images are constant for a whole session, so
    /// the bake runs once per session and is answered from the identity
    /// cache on every later tick.
    private static func masked(_ layer: CGImage, by mask: CGImage) -> CGImage? {
        if let cached = maskBake, cached.layer === layer, cached.mask === mask {
            return cached.baked
        }
        let (w, h) = (layer.width, layer.height)
        guard w > 0, h > 0,
              let context = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        context.clip(to: rect, mask: mask)
        context.draw(layer, in: rect)
        guard let baked = context.makeImage() else { return nil }
        maskBake = (layer, mask, baked)
        return baked
    }
}
