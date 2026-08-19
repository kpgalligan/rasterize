import AppKit
import ImageIO

/// The CoreGraphics ⇄ core-buffer seam: turning what macOS decoded or drew
/// into the STRAIGHT (non-premultiplied) RGBA8 the FFI takes, row 0 = top.
///
/// It exists because a few pixel sources are the platform's and not the
/// core's — glyph rasterization (TextLayer), HEIC/HEIF stills and Live Photo
/// video frames (LivePhotoLayer) — and CoreGraphics only ever renders into
/// PREMULTIPLIED buffers. Every one of those paths converts here, so the
/// unpremultiply rounding is written exactly once.
enum Bitmap {
    /// `image` rendered into a `width × height` straight-alpha RGBA8 buffer
    /// (row 0 = top, exactly `width * height * 4` bytes): scaled to FIT and
    /// centered, with transparent margins if the aspect ratios differ, so
    /// nothing is stretched or cropped. nil for a degenerate size, one past
    /// the core's pixel cap, or a context CoreGraphics refuses to make.
    static func straightRGBA(from image: CGImage, fitting width: Int, height: Int) -> [UInt8]? {
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
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
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
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let quarterTurned = (5...8).contains(orientation)
        return CGSize(
            width: quarterTurned ? height : width, height: quarterTurned ? width : height)
    }
}

extension RasterImage {
    /// A still image file decoded by the PLATFORM (see `Bitmap.decodeImage`)
    /// and handed to the core as pixels — the open path for formats the core
    /// itself cannot decode. nil when ImageIO cannot read the file.
    static func decoded(from url: URL) -> RasterImage? {
        guard let image = Bitmap.decodeImage(url),
              let pixels = Bitmap.straightRGBA(
                from: image, fitting: image.width, height: image.height)
        else { return nil }
        return RasterImage.from(rgba: pixels, width: image.width, height: image.height)
    }
}
