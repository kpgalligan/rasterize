import AppKit
import CoreVideo
import Vision

/// Subject segmentation through Vision: the model behind Preview's *Copy
/// Subject* and the long-press subject lift in Photos, driving Select >
/// Select Subject, the Subject tool, and the agent's `select_subject`.
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
    /// `CanvasSelection(shape: .mask(…))`. This is the stateless entry point
    /// — the menu command and the agent each want one answer and nothing
    /// kept; the Subject TOOL holds a `SubjectAnalysis` instead, which is
    /// what this is built on.
    static func mask(in image: CGImage, instance: Int? = nil) throws -> Subjects {
        let analysis = try SubjectAnalysis(image: image)
        let coverage: [UInt8]?
        if let instance = instance {
            guard instance >= 1, instance <= analysis.instanceCount else {
                throw Failure.instanceOutOfRange(
                    requested: instance, found: analysis.instanceCount)
            }
            coverage = analysis.mask(subject: instance)
        } else {
            coverage = analysis.maskForAllSubjects()
        }
        guard let mask = coverage else { throw Failure.unreadableMask }
        return Subjects(mask: mask, instanceCount: analysis.instanceCount)
    }

    /// Vision's mask buffer as canvas-sized coverage bytes.
    ///
    /// `generateScaledMaskForImage` returns the mask at the request image's
    /// size, so the resample at the end is a safety net rather than the
    /// normal path; it is still here because a silently mis-sized mask
    /// would build a selection that does not line up with the canvas.
    ///
    /// fileprivate rather than private: SubjectAnalysis is the only other
    /// caller and it lives in this file.
    fileprivate static func coverage(
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

/// One composite's segmentation, kept so a pointer can be hit-tested against
/// it as often as a drag demands.
///
/// The cheap hit test is what makes the Subject tool's press-and-hold
/// affordable. Vision produces `instanceMask` — a per-pixel map of INSTANCE
/// IDS, 0 for background — as a by-product of the request, so answering
/// "which subject is under this point" is one byte read instead of
/// generating and testing a mask per subject.
///
/// That map is a fixed square (512×512 today) whatever the image's shape,
/// and it is a straight non-uniform SQUASH rather than a letterboxed fit —
/// measured by scaling each subject's box out of the map and comparing it
/// against the same box taken from the full-resolution mask, over aspect
/// ratios from 0.31 to 3.2, where they agreed to within one map cell every
/// time. So mapping a canvas point into it is a plain proportional scale on
/// each axis with no padding to undo. The cell size (image ÷ 512) is the
/// hit test's granularity — a few pixels on a photo, far below the accuracy
/// anyone clicks a person with, and the reason the MASK is still generated
/// at full size separately.
final class SubjectAnalysis {
    let width: Int
    let height: Int
    var instanceCount: Int { instances.count }

    private let handler: VNImageRequestHandler
    private let observation: VNInstanceMaskObservation
    /// Vision's own ids for the subjects, ascending, in both the forms this
    /// needs. Callers address subjects by 1-based POSITION in `instances`,
    /// so the numbering they see is contiguous whatever ids Vision chose.
    private let instances: [Int]
    private let instanceSet: IndexSet
    private let ids: [UInt8]
    private let idWidth: Int
    private let idHeight: Int
    /// Full-resolution coverage per subject, built on demand and kept:
    /// dragging back onto a subject must not pay for it a second time.
    private var maskCache: [Int: [UInt8]] = [:]

    /// Runs the segmentation. Every throw happens before the first stored
    /// property is assigned, so a failure leaves nothing half-built.
    init(image: CGImage) throws {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw SubjectSelection.Failure.vision(error.localizedDescription)
        }
        // An image with nothing salient in it yields no observation at all,
        // which is a refusal and not an error.
        guard let observation = request.results?.first else {
            throw SubjectSelection.Failure.noSubject
        }
        // Vision numbers the background 0 and the subjects upward from 1.
        // `allInstances` already excludes the background, but asking for
        // index 0 explicitly returns the background mask — the exact
        // INVERSE of what anyone wants here — so it never gets through.
        var all = observation.allInstances
        all.remove(0)
        guard !all.isEmpty else { throw SubjectSelection.Failure.noSubject }
        guard let map = Self.idMap(observation.instanceMask) else {
            throw SubjectSelection.Failure.unreadableMask
        }

        self.width = image.width
        self.height = image.height
        self.handler = handler
        self.observation = observation
        self.instances = Array(all)
        self.instanceSet = all
        self.ids = map.ids
        self.idWidth = map.width
        self.idHeight = map.height
    }

    /// The subject under a canvas point (1-based), or nil over background —
    /// a single byte read, which is why this may run on every mouse-moved
    /// event.
    func subject(at point: CGPoint) -> Int? {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let mx = min(idWidth - 1, x * idWidth / width)
        let my = min(idHeight - 1, y * idHeight / height)
        let id = Int(ids[my * idWidth + mx])
        guard id != 0, let index = instances.firstIndex(of: id) else { return nil }
        return index + 1
    }

    /// Full-resolution coverage for one subject (1-based), memoized.
    func mask(subject index: Int) -> [UInt8]? {
        guard index >= 1, index <= instances.count else { return nil }
        if let cached = maskCache[index] { return cached }
        guard let mask = scaledMask(IndexSet(integer: instances[index - 1])) else { return nil }
        maskCache[index] = mask
        return mask
    }

    /// Full-resolution coverage of every subject at once.
    func maskForAllSubjects() -> [UInt8]? {
        scaledMask(instanceSet)
    }

    private func scaledMask(_ wanted: IndexSet) -> [UInt8]? {
        guard
            let buffer = try? observation.generateScaledMaskForImage(
                forInstances: wanted, from: handler)
        else { return nil }
        return SubjectSelection.coverage(buffer, width: width, height: height)
    }

    /// The instance-id map as plain bytes.
    ///
    /// Not a duplicate of `SubjectSelection.coverage` despite the shape: the
    /// values here are IDS, not coverage, so the float form rounds the raw
    /// number instead of scaling it by 255.
    private static func idMap(
        _ buffer: CVPixelBuffer
    ) -> (width: Int, height: Int, ids: [UInt8])? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer)
        else { return nil }
        var ids = [UInt8](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                let out = y * width
                for x in 0..<width {
                    ids[out + x] = row[x]
                }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
                let out = y * width
                for x in 0..<width {
                    ids[out + x] = UInt8(max(0, min(255, row[x].rounded())))
                }
            }
        default:
            return nil
        }
        return (width, height, ids)
    }
}

/// The press-and-hold gesture behind the Subject tool: while the mouse is
/// down, the subject under the pointer is outlined; releasing turns that
/// outline into the selection.
///
/// The gesture is affordable because of how `SubjectAnalysis` is shaped —
/// Vision runs once per composite and the hit test after that is a byte
/// read, so dragging across a photo can re-outline continuously. Only
/// landing on a subject for the FIRST time costs a mask, and that is
/// remembered for the rest of the gesture.
struct SubjectSession {
    /// The analysis and the exact composite it describes. Identity is the
    /// invalidation rule and it is exact: every edit hands the canvas a
    /// freshly made CGImage, so a stale analysis cannot survive one.
    private var analysis: SubjectAnalysis?
    private var analyzed: CGImage?

    /// The subject under the pointer (1-based), its coverage as a selection
    /// ready to commit, and the contour to draw. All nil over background.
    private(set) var subject: Int?
    private(set) var selection: CanvasSelection?
    private(set) var outline: NSBezierPath?

    /// How many subjects the current composite has — 0 when the
    /// segmentation found none at all, which is worth saying out loud
    /// rather than leaving as a dead click.
    var subjectCount: Int { analysis?.instanceCount ?? 0 }

    /// Points the gesture at `point`, analysing `image` first if it is one
    /// this has not seen. Returns true when the outline changed and the
    /// canvas needs a redraw.
    mutating func hover(_ point: CGPoint, in image: CGImage?) -> Bool {
        guard let image = image else { return clear() }
        var changed = false
        if analyzed !== image {
            analyzed = image
            // The one expensive step, and it lands on mouse-down rather
            // than mid-drag: ~30 ms for the request on a photo, plus the
            // model load on the very first use in a session.
            analysis = try? SubjectAnalysis(image: image)
            changed = clear()
        }
        guard let analysis = analysis, let hit = analysis.subject(at: point) else {
            return clear() || changed
        }
        guard hit != subject else { return changed }
        guard let mask = analysis.mask(subject: hit),
              let found = CanvasSelection(
                shape: .mask(mask), canvasWidth: analysis.width, canvasHeight: analysis.height)
        else { return clear() || changed }
        subject = hit
        selection = found
        // maskContour is the marching-squares trace CanvasSelection already
        // builds for wand marquees, so the outline costs nothing extra.
        outline = found.marqueePath
        return true
    }

    /// Ends the gesture, handing back the selection to commit — nil when the
    /// press ended over the background.
    mutating func end() -> CanvasSelection? {
        let committed = selection
        clear()
        return committed
    }

    /// Drops the outline without committing anything.
    mutating func cancel() {
        clear()
    }

    @discardableResult
    private mutating func clear() -> Bool {
        let hadOutline = subject != nil
        subject = nil
        selection = nil
        outline = nil
        return hadOutline
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
