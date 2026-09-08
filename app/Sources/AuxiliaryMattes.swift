import AVFoundation
import CoreVideo
import ImageIO

/// iPhone auxiliary images — depth/disparity, the portrait-effects matte
/// and the semantic segmentation mattes — read off a HEIC or JPEG at open
/// time and attached as named alpha channels, resampled to the canvas.
///
/// It sits on the same seam as `LivePhotoLayer`: the PLATFORM decodes (only
/// ImageIO and AVFoundation can read these) and the core only stores the
/// coverage plane that came out — including the matte→canvas scale, which
/// `rz_doc_add_channel` does with the same bilinear resampler Image Size
/// already runs on a layer mask, so no second scaling implementation lands
/// on this side of the seam.
///
/// Both open paths attach: "Most Compatible" mode writes JPEGs carrying the
/// same auxiliary images, and a JPEG is decoded by the core. A file with
/// none costs one CGImageSourceCreateWithURL plus a handful of nil-returning
/// lookups. A Live Photo (a HEIC beside a same-basename .mov) wins earlier
/// in the open ladder and contributes no channels — documented, not fixed.
///
/// Nothing here can crash on a malformed auxiliary dictionary: every entry
/// point is an optional or a `throws` initialiser, with the single
/// exception called out at `disparity(from:)`.
enum AuxiliaryMattes {
    /// One matte at its OWN size; the core resamples it to the canvas.
    /// Mattes are routinely a different resolution from the photo — a depth
    /// map is much smaller, a portrait matte can be larger.
    struct Plane {
        let name: String
        let width: Int
        let height: Int
        /// `width * height` bytes, row 0 = top — the coverage convention.
        let samples: [UInt8]
    }

    /// The auxiliary types read, in the order their channels are appended:
    /// depth first because it is the one a user reaches for, then the
    /// portrait matte, then the semantic mattes in Apple's own order.
    /// Disparity and Depth are the SAME channel from the user's side (a
    /// file carries one or the other), so they share a name and the first
    /// one found wins — disparity leads because it needs no conversion.
    private static let sources: [(type: CFString, name: String)] = [
        (kCGImageAuxiliaryDataTypeDisparity, "Depth"),
        (kCGImageAuxiliaryDataTypeDepth, "Depth"),
        (kCGImageAuxiliaryDataTypePortraitEffectsMatte, "Portrait Matte"),
        (kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, "Skin"),
        (kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, "Hair"),
        (kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, "Teeth"),
        (kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, "Glasses"),
        (kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte, "Sky"),
    ]

    /// Every auxiliary image the file carries, in Apple's own order, each
    /// oriented to match the pixels the document was opened with — both
    /// decoders bake the EXIF rotation in (`Bitmap.decodeImage` through
    /// `kCGImageSourceCreateThumbnailWithTransform`, the core through
    /// `apply_orientation`) while auxiliary data is stored UNROTATED, so a
    /// matte that skipped this would land sideways on a portrait photo.
    /// Empty for an ordinary photo. Never throws and never crashes on a
    /// malformed auxiliary dictionary.
    static func planes(in url: URL) -> [Plane] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return [] }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        // EXIF orientation is 1...8; a missing or nonsense tag reads as 1
        // ("up"), the same degradation `Bitmap.imageSize` already applies.
        let raw = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(exactly: raw) ?? 1) ?? .up

        var found: [Plane] = []
        for entry in sources where !found.contains(where: { $0.name == entry.name }) {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, entry.type)
                as? [AnyHashable: Any],
                  let buffer = mattingImage(entry.type, info, orientation),
                  let matte = plane(from: buffer, name: entry.name)
            else { continue }
            found.append(matte)
        }
        return found
    }

    /// The pixel buffer behind one auxiliary dictionary, already rotated to
    /// the displayed orientation. The dictionary is handed to AVFoundation
    /// whole rather than parsed by hand — its layout is Apple's, and every
    /// one of these initialisers throws rather than trapping on a corrupt
    /// one. Depth and disparity go through `disparity(from:)` so a depth map
    /// and a disparity map produce the same channel; the mattes are already
    /// 8-bit coverage.
    private static func mattingImage(
        _ type: CFString, _ info: [AnyHashable: Any],
        _ orientation: CGImagePropertyOrientation
    ) -> CVPixelBuffer? {
        if type == kCGImageAuxiliaryDataTypeDepth || type == kCGImageAuxiliaryDataTypeDisparity {
            guard let depth = try? AVDepthData(fromDictionaryRepresentation: info) else {
                return nil
            }
            return disparity(from: depth.applyingExifOrientation(orientation)).depthDataMap
        }
        if type == kCGImageAuxiliaryDataTypePortraitEffectsMatte {
            guard let matte = try? AVPortraitEffectsMatte(fromDictionaryRepresentation: info)
            else { return nil }
            return matte.applyingExifOrientation(orientation).mattingImage
        }
        guard let matte = try? AVSemanticSegmentationMatte(
            fromImageSourceAuxiliaryDataType: type, dictionaryRepresentation: info)
        else { return nil }
        return matte.applyingExifOrientation(orientation).mattingImage
    }

    /// `depth` as 32-bit DISPARITY when the data offers that conversion.
    /// Disparity is 1/distance, so NEAR is the large value and the
    /// normalized channel comes out white where the subject is — the
    /// convention Photos itself shows, and the one that makes the channel
    /// usable as a selection without inverting it first.
    ///
    /// `converting(toDepthDataType:)` raises an Objective-C
    /// NSInvalidArgumentException — which Swift cannot catch — for a type
    /// the data cannot produce, so the `availableDepthDataTypes` membership
    /// check is load-bearing, not defensive politeness. Unconvertible data
    /// is normalized as it stands and `plane(from:name:)` inverts a
    /// depth-typed buffer instead.
    private static func disparity(from depth: AVDepthData) -> AVDepthData {
        let target = kCVPixelFormatType_DisparityFloat32
        if depth.depthDataType == target { return depth }
        guard depth.availableDepthDataTypes.contains(target) else { return depth }
        return depth.converting(toDepthDataType: target)
    }

    /// One CVPixelBuffer as an 8-bit coverage plane. `OneComponent8` copies
    /// row by row (the buffer is padded to its stride, `[UInt8]` is not);
    /// the float depth formats are normalized over their FINITE range — a
    /// depth map marks unknown pixels NaN or infinity, and those become 0
    /// (unselected) rather than poisoning the range. A depth-typed (rather
    /// than disparity-typed) buffer is inverted so near stays white.
    ///
    /// nil for a format we do not know, a lock failure, a degenerate size,
    /// one past the core's pixel cap (`maxResizePixels`, the same bound
    /// every buffer crossing the FFI is held to), or a row stride too short
    /// for its own width.
    private static func plane(from buffer: CVPixelBuffer, name: String) -> Plane? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        // Each side is bounded before the product is formed, so a nonsense
        // dimension out of a corrupt buffer cannot overflow the multiply
        // that the pixel cap is then checked against.
        guard width > 0, height > 0, width <= RasterImage.maxResizePixels,
              height <= RasterImage.maxResizePixels,
              width * height <= RasterImage.maxResizePixels,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        var samples = [UInt8](repeating: 0, count: width * height)
        switch format {
        case kCVPixelFormatType_OneComponent8:
            guard stride >= width else { return nil }
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    samples[y * width + x] = row[x]
                }
            }
        case kCVPixelFormatType_DisparityFloat32, kCVPixelFormatType_DepthFloat32:
            guard stride >= width * MemoryLayout<Float32>.size else { return nil }
            // `loadUnaligned` rather than a bound pointer: CoreVideo only
            // promises the stride, not that a row starts on the element's
            // alignment.
            let read: (Int, Int) -> Float = { x, y in
                Float(base.loadUnaligned(
                    fromByteOffset: y * stride + x * MemoryLayout<Float32>.size,
                    as: Float32.self))
            }
            normalize(read, into: &samples, width: width, height: height,
                      invert: format == kCVPixelFormatType_DepthFloat32)
        case kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DepthFloat16:
            guard stride >= width * MemoryLayout<Float16>.size else { return nil }
            let read: (Int, Int) -> Float = { x, y in
                Float(base.loadUnaligned(
                    fromByteOffset: y * stride + x * MemoryLayout<Float16>.size,
                    as: Float16.self))
            }
            normalize(read, into: &samples, width: width, height: height,
                      invert: format == kCVPixelFormatType_DepthFloat16)
        default:
            return nil
        }
        return Plane(name: name, width: width, height: height, samples: samples)
    }

    /// Two passes over a float plane: the finite range, then a linear map
    /// onto 0...255 (`invert` flips it, so a DEPTH map — where large means
    /// far — still comes out white where the subject is). The range is
    /// measured rather than assumed because a depth map's units are metres
    /// or reciprocal metres and its span is whatever the scene was.
    ///
    /// Non-finite samples read 0. A degenerate range (one distance
    /// everywhere, or no finite sample at all) leaves the plane 0: a channel
    /// that selects nothing is honest about carrying no information, and the
    /// user can still delete it.
    private static func normalize(
        _ read: (Int, Int) -> Float, into samples: inout [UInt8],
        width: Int, height: Int, invert: Bool
    ) {
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        for y in 0..<height {
            for x in 0..<width {
                let value = read(x, y)
                guard value.isFinite else { continue }
                low = min(low, value)
                high = max(high, value)
            }
        }
        let span = high - low
        guard span > 0, span.isFinite else { return }
        for y in 0..<height {
            for x in 0..<width {
                let value = read(x, y)
                guard value.isFinite else { continue }
                let t = (value - low) / span
                // 255 is the coverage convention's "fully selected", the
                // same scale a selection mask and a layer mask use.
                let scaled = (invert ? 1 - t : t) * 255
                samples[y * width + x] = UInt8(max(0, min(255, scaled.rounded())))
            }
        }
    }

    /// `document` with one channel per auxiliary image, or nil when the
    /// file carries none (so the caller keeps its own handle and the common
    /// case costs nothing). A channel the core refuses — including a
    /// refusal from the channel budget — is skipped while the rest land.
    static func attaching(to document: RasterDocument, from url: URL) -> RasterDocument? {
        let found = planes(in: url)
        guard !found.isEmpty else { return nil }
        var out = document
        for plane in found {
            guard
                let next = out.addingChannel(
                    name: plane.name, plane: plane.samples, width: plane.width,
                    height: plane.height)
            else { continue }
            out = next
        }
        return out === document ? nil : out
    }
}
