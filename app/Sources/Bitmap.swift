import AppKit
import ImageIO

/// The CoreGraphics ⇄ core-buffer seam: turning what macOS decoded or drew
/// into the STRAIGHT (non-premultiplied) RGBA8 the FFI takes, row 0 = top.
///
/// It exists because a few pixel sources are the platform's and not the
/// core's — glyph rasterization (TextLayer), shape paths (ShapeLayer),
/// HEIC/HEIF stills and Live Photo video frames (LivePhotoLayer) — and
/// CoreGraphics only ever renders into PREMULTIPLIED buffers. Every one of
/// those paths converts here, so the unpremultiply rounding is written
/// exactly once, and the three described-layer renderers share ONE context
/// builder (`renderStraightRGBA`) so their placement rule is written once
/// too (DescribedLayer.swift).
///
/// It is also where the COLOUR rule for ingest is enforced: **the platform
/// decodes, the core converts.** Every context here is built in a caller-
/// supplied space with no default, so a caller must say which numbers it
/// wants out — the source image's own (`ingestSpace`, which converts
/// nothing) or the document's (a glyph, a shape fill, a re-rendered frame,
/// which CoreGraphics converts into once). The single conversion between
/// spaces then belongs to the core, where it is tested.
enum Bitmap {
    /// `image` rendered into a `width × height` straight-alpha RGBA8 buffer
    /// (row 0 = top, exactly `width * height * 4` bytes): scaled to FIT and
    /// centered, with transparent margins if the aspect ratios differ, so
    /// nothing is stretched or cropped. nil for a degenerate size, one past
    /// the core's pixel cap, or a context CoreGraphics refuses to make.
    ///
    /// `space` is the space the RESULTING BYTES are in: CoreGraphics colour-
    /// matches `image` into it. Pass `ingestSpace(of:).space` to convert
    /// nothing, or a document's space to land the document's own numbers.
    static func straightRGBA(
        from image: CGImage, fitting width: Int, height: Int, space: CGColorSpace
    ) -> [UInt8]? {
        guard width > 0, height > 0, width * height <= RasterImage.maxResizePixels,
              image.width > 0, image.height > 0
        else { return nil }
        let scale = min(
            CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawWidth = max(CGFloat(image.width) * scale, 1)
        let drawHeight = max(CGFloat(image.height) * scale, 1)
        let rect = CGRect(
            x: (CGFloat(width) - drawWidth) / 2, y: (CGFloat(height) - drawHeight) / 2,
            width: drawWidth, height: drawHeight)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // A bitmap context stores its first row at the TOP of what it
            // draws, which is the core's convention too — so, unlike the
            // flipped context the text renderer needs for glyph layout, this
            // one draws straight through.
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            return true
        }
        guard drawn else { return nil }
        unpremultiply(&pixels)
        return pixels
    }

    /// Renders `draw` into a `width × height` straight-alpha RGBA8 buffer
    /// (row 0 = top): a premultiplied context in `space` flipped so y grows
    /// DOWN (CoreText and the shape paths draw in the canvas's own
    /// orientation), then the ONE unpremultiply. Every caller passes the
    /// document's DRAWING space (`RasterDocument.drawingSpace`), so an
    /// authored colour — a glyph's, a shape fill's — is converted into the
    /// document's numbers exactly once, here, by CoreGraphics. `draw`
    /// receives the context with the flip already applied and returns false
    /// to abort. `appKit: true`
    /// additionally pushes an NSGraphicsContext around `draw` — required by
    /// NSAttributedString drawing, and MAIN THREAD ONLY (AppKit drawing); the
    /// shape and Live Photo renderers leave it false and stay pure
    /// CoreGraphics, which is what lets the Live Photo sheet preview render
    /// on PreviewRenderer's queue. nil for a degenerate size, one past the
    /// core's pixel cap, a context CoreGraphics refuses, or an aborted draw.
    static func renderStraightRGBA(
        width: Int, height: Int, appKit: Bool = false, space: CGColorSpace,
        _ draw: (CGContext) -> Bool
    ) -> [UInt8]? {
        guard width > 0, height > 0, width * height <= RasterImage.maxResizePixels else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBufferPointer { buffer -> Bool in
            // CoreGraphics renders only into PREMULTIPLIED buffers; the
            // straight-alpha conversion happens below.
            guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // Flip so raster row 0 is the top row, as everywhere else.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            guard appKit else { return draw(context) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let ok = draw(context)
            NSGraphicsContext.restoreGraphicsState()
            return ok
        }
        guard drawn else { return nil }
        unpremultiply(&pixels)
        return pixels
    }

    /// Straight-alpha conversion of a premultiplied RGBA8 buffer in place:
    /// layer pixels cross the FFI with straight alpha (only the painting
    /// overlay is premultiplied). Fully transparent pixels carry no color at
    /// all.
    static func unpremultiply(_ pixels: inout [UInt8]) {
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            if alpha == 255 { continue }
            if alpha == 0 {
                pixels[i] = 0
                pixels[i + 1] = 0
                pixels[i + 2] = 0
                continue
            }
            for channel in 0..<3 {
                let value = (Int(pixels[i + channel]) * 255 + alpha / 2) / alpha
                pixels[i + channel] = UInt8(min(value, 255))
            }
        }
    }

    /// Decodes a still image file through ImageIO — the platform decoders,
    /// which cover the formats the Rust core has none for (HEIC, HEIF) as
    /// well as the ones it does. Camera-tagged rotation is baked into the
    /// pixels, matching what the core does at open time, so callers never
    /// have to think about EXIF orientation.
    ///
    /// `maxSide` caps the longest side (0 = full size), which is what makes
    /// a preview cheap: ImageIO decodes to the requested size instead of
    /// producing a full-resolution image to throw away.
    static func decodeImage(_ url: URL, maxSide: Int = 0) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        // The transform-applying path is the thumbnail API even at full size;
        // "thumbnail" here only means "decoded to a bounding size".
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let fullSide = max(pixelWidth, pixelHeight, 1)
        let bound = maxSide > 0 ? min(maxSide, fullSide) : fullSide
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bound,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        // Fallback for anything ImageIO will decode but not "thumbnail":
        // orientation is then whatever the file says, which is the same
        // degradation an unreadable EXIF tag already produces.
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The pixel size an image file DISPLAYS at, without decoding it: the
    /// stored dimensions, swapped when the EXIF orientation is one of the
    /// four quarter-turned ones (5-8) — which is the size `decodeImage`
    /// produces, since it bakes that rotation in. nil when ImageIO cannot
    /// read the file's properties.
    static func imageSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let turned = quarterTurned(properties)
        return CGSize(width: turned ? height : width, height: turned ? width : height)
    }

    /// True when the file's EXIF orientation is one of the four quarter
    /// turns (5-8), so the stored width is the DISPLAYED height. The ONE
    /// place that rule is written on this side: `decodeImage` bakes the
    /// rotation in, so both the size and the resolution below are read
    /// through it.
    private static func quarterTurned(_ properties: [CFString: Any]) -> Bool {
        (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    /// The print resolution a still image file declares, in pixels per inch
    /// per axis, or nil when it declares none. ImageIO reports the same
    /// number for JFIF density, PNG `pHYs` and the EXIF resolution tags, so
    /// this is the platform decode path's answer to the core's own
    /// `metadata::scan`. Non-positive or non-finite values are treated as
    /// absent — a 0 dpi file states nothing.
    ///
    /// The pair is transposed for a quarter-turned file, exactly as
    /// `imageSize` transposes the dimensions and for the same reason: the
    /// file states its resolution for the picture as STORED, and
    /// `decodeImage` returns it upright. A 300 x 150 ppi frame stored
    /// sideways is a 150 x 300 ppi picture. The core's own open path applies
    /// the same rule (`rz_image::open_bytes`).
    static func imageDPI(_ url: URL) -> (Double, Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let x = properties[kCGImagePropertyDPIWidth] as? NSNumber,
              let y = properties[kCGImagePropertyDPIHeight] as? NSNumber
        else { return nil }
        // NSNumber, not a Swift Double cast: ImageIO reports an integral
        // density as an integer CFNumber for most files.
        let (dx, dy) = (x.doubleValue, y.doubleValue)
        guard dx.isFinite, dy.isFinite, dx > 0, dy > 0 else { return nil }
        return quarterTurned(properties) ? (dy, dx) : (dx, dy)
    }

    /// The frontmost pasteboard image as a CGImage, normalized through
    /// `NSBitmapImageRep` so the result has the source's real PIXEL
    /// dimensions (an NSImage's own size is in points) and carries the
    /// colour space its numbers belong to. nil when the pasteboard holds no
    /// image.
    ///
    /// This is the pasteboard's half of the ingest rule: it DECODES and
    /// converts nothing, leaving the caller to say which numbers it wants —
    /// `RasterImage.fromPasteboard` for a new document, its `in:` twin for
    /// pixels joining an existing one.
    static func pasteboardImage(_ pasteboard: NSPasteboard) -> CGImage? {
        guard let pasted = NSImage(pasteboard: pasteboard),
              let tiff = pasted.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.cgImage
    }

    /// The space to DECODE `image` into so that nothing is converted, plus
    /// the ICC bytes those numbers belong to — the pair a caller hands to
    /// `straightRGBA` and then assigns to the document, which is what makes
    /// "the platform converts nothing" true rather than hopeful.
    ///
    /// The image's own space qualifies only when it is RGB with three
    /// components, exports ICC bytes we could re-embed, and a 1×1 probe
    /// context can actually be built from it — an extended-range or
    /// otherwise unusual space is rejected by that probe rather than by
    /// guesswork, since a context CoreGraphics refuses would fail the whole
    /// decode. Otherwise the answer is sRGB with no profile: the decode then
    /// converts into sRGB, which is exactly what the numbers will be.
    static func ingestSpace(of image: CGImage) -> (space: CGColorSpace, profile: Data?) {
        ingestSpace(of: image.colorSpace)
    }

    /// The same question asked of a bare space, for a decode that has one
    /// without a `CGImage` to read it from — Core Image's RAW develop, which
    /// renders into `CIImage.colorSpace` (`RawImage.develop`).
    ///
    /// It is the ONE home for the rule, and the CGImage form above is this
    /// plus one property read. The two were written out twice, and a later
    /// phase tightening the rule — refusing a space whose ICC bytes the
    /// core's parser will not take, say — would have landed here and
    /// silently missed the RAW path, so the same photograph would have been
    /// labelled with a different profile depending on which decoder read it.
    static func ingestSpace(of space: CGColorSpace?) -> (space: CGColorSpace, profile: Data?) {
        guard let space = space, space.model == .rgb, space.numberOfComponents == 3,
              CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) != nil,
              let icc = space.copyICCData() as Data?
        else { return (ColorProfile.sRGB, nil) }
        return (space, icc)
    }

    /// `image` converted to sRGB, or `image` itself when it already is one
    /// — the agent `render` exit's conversion, which lives here because
    /// this file is the documented CoreGraphics⇄core seam.
    ///
    /// The short-circuit is load-bearing, not an optimization: a render of
    /// an sRGB document must return the same bytes it always did, and a
    /// needless premultiply/unpremultiply round trip would perturb
    /// partially transparent pixels and zero the RGB under fully
    /// transparent ones. nil only when CoreGraphics refuses the conversion.
    static func sRGBCopy(of image: CGImage) -> CGImage? {
        if let space = image.colorSpace, CFEqual(space, ColorProfile.sRGB) { return image }
        let (w, h) = (image.width, image.height)
        guard let pixels = straightRGBA(
                from: image, fitting: w, height: h, space: ColorProfile.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData)
        else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: ColorProfile.sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension RasterImage {
    /// A still image file decoded by the PLATFORM (see `Bitmap.decodeImage`)
    /// and handed to the core as pixels — the open path for formats the core
    /// itself cannot decode. nil when ImageIO cannot read the file.
    ///
    /// The decode goes into the SOURCE image's own space (`ingestSpace`), so
    /// it converts nothing; `profile` is the ICC bytes those pixel numbers
    /// belong to and the caller assigns them to the document, leaving the
    /// core's `adopt_working_space` to do the one conversion. EXIF, XMP and
    /// IPTC are NOT captured on this path (HEIC/HEIF contribute their ICC
    /// profile and dpi only) — a known limit of this phase.
    static func decoded(
        from url: URL
    ) -> (image: RasterImage, profile: Data?, dpi: (Double, Double)?)? {
        guard let image = Bitmap.decodeImage(url) else { return nil }
        let ingest = Bitmap.ingestSpace(of: image)
        guard let pixels = Bitmap.straightRGBA(
                from: image, fitting: image.width, height: image.height, space: ingest.space),
              let raster = RasterImage.from(
                rgba: pixels, width: image.width, height: image.height)
        else { return nil }
        return (raster, ingest.profile, Bitmap.imageDPI(url))
    }

    /// The frontmost pasteboard image for a NEW document (File > New from
    /// Clipboard): decoded into its OWN space, so nothing is converted, plus
    /// the ICC bytes those numbers belong to. The caller assigns that
    /// profile and then lets `adoptWorkingSpace` do the single conversion —
    /// the same three steps `decoded(from:)` exists for, because a
    /// screenshot on a modern Mac is Display P3 and labelling those numbers
    /// sRGB is how the same picture came to look different depending on
    /// whether it was opened or pasted.
    static func fromPasteboard(
        _ pasteboard: NSPasteboard = .general
    ) -> (image: RasterImage, profile: Data?)? {
        guard let image = Bitmap.pasteboardImage(pasteboard) else { return nil }
        let ingest = Bitmap.ingestSpace(of: image)
        guard let raster = pasted(image, in: ingest.space) else { return nil }
        return (raster, ingest.profile)
    }

    /// The frontmost pasteboard image for pixels joining an EXISTING
    /// document (Paste, Paste as New Layer): decoded straight into `space`
    /// — the destination document's drawing space — because a layer's bytes
    /// have to be the document's own numbers. CoreGraphics performs that one
    /// conversion; there is no profile to hand back, since the pixels now
    /// belong to the document's.
    static func fromPasteboard(
        _ pasteboard: NSPasteboard = .general, in space: CGColorSpace
    ) -> RasterImage? {
        Bitmap.pasteboardImage(pasteboard).flatMap { pasted($0, in: space) }
    }

    private static func pasted(_ image: CGImage, in space: CGColorSpace) -> RasterImage? {
        guard let pixels = Bitmap.straightRGBA(
                from: image, fitting: image.width, height: image.height, space: space)
        else { return nil }
        return RasterImage.from(rgba: pixels, width: image.width, height: image.height)
    }
}
