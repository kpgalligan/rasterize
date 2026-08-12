import AppKit
import CoreVideo
import Vision

/// Subject segmentation through Vision: the model behind Preview's *Copy
/// Subject* and the long-press subject lift in Photos, driving Select >
/// Select Subject and the agent's `select_subject`.
///
/// It needs no translation layer to land in our selection model, which is
/// the reason this file is short. `VNGenerateForegroundInstanceMaskRequest`
/// returns coverage in 0…1 with soft edges; a `CanvasSelection` is
/// canvas-sized u8 coverage, row 0 = top, 0 outside, 255 inside,
/// intermediate at anti-aliased edges. So the whole conversion is a
/// float→byte scale that honours the buffer's row padding, and the model's
/// soft edge arrives as a genuinely feathered selection rather than a
/// staircase.
///
/// Deliberately SYNCHRONOUS, against the usual instinct for anything with a
/// neural network in it. Measured on this hardware the request costs ~200 ms
/// on its first call (loading the model) and 25–50 ms after, and it is FLAT
/// in image size — 48 MP costs no more than 0.5 MP, because the network
/// resizes internally and only the mask scales with the canvas. That fits a
/// menu command's budget, so this adds no background queue and no new
/// concurrency seam.
enum SubjectSelection {
    /// A segmentation result: coverage over the whole canvas, plus how many
    /// distinct subjects the model separated — reported so a caller can
    /// come back for a specific one.
    struct Subjects {
        let mask: [UInt8]
        let instanceCount: Int
    }

    /// Why a segmentation produced no selection. The cases are separate
    /// because the agent surfaces them as distinct errors and the UI picks
    /// a sentence from them.
    enum Failure: Error {
        case noComposite
        case noSubject
        case instanceOutOfRange(requested: Int, found: Int)
        case unreadableMask
        case vision(String)

        var message: String {
            switch self {
            case .noComposite:
                return "The document could not be flattened for subject detection."
            case .noSubject:
                return "No subject was found in the image."
            case .instanceOutOfRange(let requested, let found):
                return "There is no subject \(requested); the image has \(found)."
            case .unreadableMask:
                return "The segmentation mask came back in a format we cannot read."
            case .vision(let reason):
                return "Subject detection failed: \(reason)"
            }
        }
    }

    /// Coverage of every foreground subject in `image`, or of one of them
    /// (`instance`, 1-based, in Vision's own order).
    ///
    /// The mask is exactly `image.width * image.height` bytes with row 0 at
    /// the top, so the caller hands it straight to
    /// `CanvasSelection(shape: .mask(…))`.
    static func mask(in image: CGImage, instance: Int? = nil) throws -> Subjects {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw Failure.vision(error.localizedDescription)
        }
        // An image with nothing salient in it yields no observation at all,
        // which is a refusal and not an error.
        guard let observation = request.results?.first else { throw Failure.noSubject }

        // Vision numbers the background 0 and the subjects upward from 1.
        // `allInstances` already excludes the background, but asking for
        // index 0 explicitly returns the background mask — the exact
        // INVERSE of what anyone wants here — so it never gets through.
        var instances = observation.allInstances
        instances.remove(0)
        guard !instances.isEmpty else { throw Failure.noSubject }

        let wanted: IndexSet
        if let instance = instance {
            let ordered = Array(instances)
            guard instance >= 1, instance <= ordered.count else {
                throw Failure.instanceOutOfRange(requested: instance, found: ordered.count)
            }
            wanted = IndexSet(integer: ordered[instance - 1])
        } else {
            wanted = instances
        }

        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateScaledMaskForImage(
                forInstances: wanted, from: handler)
        } catch {
            throw Failure.vision(error.localizedDescription)
        }
        guard let mask = coverage(buffer, width: image.width, height: image.height) else {
            throw Failure.unreadableMask
        }
        return Subjects(mask: mask, instanceCount: instances.count)
    }

    /// Vision's mask buffer as canvas-sized coverage bytes.
    ///
    /// `generateScaledMaskForImage` returns the mask at the request image's
    /// size, so the resample at the end is a safety net rather than the
    /// normal path; it is still here because a silently mis-sized mask
    /// would build a selection that does not line up with the canvas.
    private static func coverage(
        _ buffer: CVPixelBuffer, width: Int, height: Int
    ) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let maskWidth = CVPixelBufferGetWidth(buffer)
        let maskHeight = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard maskWidth > 0, maskHeight > 0, let base = CVPixelBufferGetBaseAddress(buffer)
        else { return nil }

        var bytes = [UInt8](repeating: 0, count: maskWidth * maskHeight)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            // Rows are PADDED — the stride is not maskWidth * 4 — so every
            // row is addressed through it rather than by multiplying out.
            for y in 0..<maskHeight {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
                let out = y * maskWidth
                for x in 0..<maskWidth {
                    bytes[out + x] = UInt8(max(0, min(255, (row[x] * 255).rounded())))
                }
            }
        case kCVPixelFormatType_OneComponent8:
            // Not what the current OS returns; accepted so a future format
            // change degrades into a working path instead of a refusal.
            for y in 0..<maskHeight {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                let out = y * maskWidth
                for x in 0..<maskWidth {
                    bytes[out + x] = row[x]
                }
            }
        default:
            return nil
        }
        guard maskWidth != width || maskHeight != height else { return bytes }
        return resampled(bytes, maskWidth, maskHeight, toWidth: width, height: height)
    }

    /// Coverage bytes resampled to the canvas, through the same gray CGImage
    /// the selection model already builds for wand masks.
    private static func resampled(
        _ bytes: [UInt8], _ sourceWidth: Int, _ sourceHeight: Int,
        toWidth width: Int, height: Int
    ) -> [UInt8]? {
        guard width > 0, height > 0,
              let image = CanvasSelection.grayImage(bytes, sourceWidth, sourceHeight)
        else { return nil }
        var scaled = [UInt8](repeating: 0, count: width * height)
        let drawn = scaled.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            // Row 0 stays the top row: a bitmap context stores its first row
            // at the top of what it draws, the same reasoning as in
            // Bitmap.straightRGBA, so this needs no flip.
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? scaled : nil
    }
}

extension RasterDocument {
    /// Subject coverage over the FLATTENED composite — segmentation reads
    /// what the user sees rather than the active layer, the same choice the
    /// magic wand makes about where to sample.
    func subjectMask(instance: Int? = nil) throws -> SubjectSelection.Subjects {
        guard let composite = flattened()?.makeCGImage() else {
            throw SubjectSelection.Failure.noComposite
        }
        return try SubjectSelection.mask(in: composite, instance: instance)
    }
}
