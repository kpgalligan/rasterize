import AppKit
import Vision

/// Red-eye removal's detection half, and the second platform-model seam
/// beside SubjectSelection.swift's foreground-instance request: it turns a
/// composite into eye discs the core op can be pointed at, and knows nothing
/// about pixels. The correction itself is `doc_redeye.rs`, driven through
/// `RasterDocument.redEyeLayer`.
///
/// The seam this file owns is the one SubjectSelection never had to cross.
/// Segmentation hands back a CVPixelBuffer, so that file's coordinate work is
/// buffer indexing; landmarks come back in Vision's own space, which puts the
/// origin at the BOTTOM-left with y growing up, while the canvas — and every
/// buffer that crosses the FFI — has row 0 at the top. So the whole
/// conversion is one subtraction, and it is written once, in `canvasPoints`,
/// and nowhere else in the feature.
///
/// Deliberately SYNCHRONOUS on the main thread, like SubjectSelection, and
/// measured before it was written because that file's own note says to
/// re-measure rather than assume. `VNDetectFaceLandmarksRequest` through
/// `VNImageRequestHandler(cgImage:)`, on this hardware:
///
/// | image | first call | warm |
/// |---|---|---|
/// | 1024×768 (samples/plasma.jpg) | 79 ms | 3–5 ms |
/// | 2000×1500 | — | 5 ms |
/// | 4000×3000 (12 MP) | — | 11–12 ms |
/// | 8000×6000 (48 MP) | 123 ms | 29–30 ms |
///
/// So unlike segmentation this request is NOT flat in image size — face
/// detection sweeps an image pyramid, and 48 MP costs roughly eight times
/// what 1 MP does — but the constant is small enough that the worst case stays
/// inside a menu command's budget, so there is still no background queue and
/// no new concurrency seam here. Detection running on a downscaled copy (the
/// escape hatch, since a face big enough to show red-eye is many pixels wide
/// at 2000 px on the long side) is therefore NOT needed and not done.
///
/// The landmark stage was measured separately, by handing the request
/// explicit `inputFaceObservations` — which the header documents as skipping
/// detection — because no image in this repo contains a face Vision will
/// find: **3 ms for one face at 1 MP, 5–6 ms for two faces at 48 MP**, i.e.
/// a per-face cost that is flat in image size (landmarks run on the face's
/// own crop). Worst case for the whole automatic pass on a 48 MP canvas is
/// therefore ~35 ms warm, ~130 ms on the first call of a session.
///
/// The detector is verified by reading, `make typecheck` and those probes
/// only: every repo sample yields zero faces, and a drawn face does not trip
/// a DNN face detector. That is the same honest limit phase 3 recorded for
/// the iPhone auxiliary mattes, and it is why the agent's `red_eye_auto`
/// takes an explicit `eyes` list — the pipeline minus the detector is
/// drivable end to end on any picture.
enum RedEye {
    /// One eye to correct, in CANVAS coordinates (row 0 = top, y down).
    struct Eye {
        let center: CGPoint
        let radius: CGFloat

        /// The rect handed to the core op: a square of side 6 · radius
        /// centred on `center`. Deliberately generous — the pupil-size gate
        /// measures a red region against the rect's SHORTER side, and a tight
        /// rect would make the gate the reason an automatic fix did nothing.
        /// At this size the iris is a third of the rect's side, so the
        /// default 100 % gate has a 3× margin, and even a rect the canvas
        /// edge clips to a third of its width still passes it.
        ///
        /// Generous, not overlapping: an eye's radius is a fifth of its own
        /// width and the two eyes sit about thirteen such radii apart, while
        /// these squares reach only three radii from each centre. Were they
        /// ever to meet — a face at an extreme angle — the second pass would
        /// find a pupil the first already neutralised, which no longer scores
        /// as red, so the correction is not applied twice.
        var rect: CGRect {
            CGRect(
                x: center.x - radius * 3, y: center.y - radius * 3,
                width: radius * 6, height: radius * 6)
        }
    }

    /// The most canvas area one automatic pass will correct, summed over its
    /// eyes.
    ///
    /// The core op is O(the rectangle), not O(the pupil): the redness scan,
    /// the 4-connected component walk and the feather all run over every
    /// pixel of the rect before the size gate rejects anything, and measured
    /// on a 5000 x 5000 document one whole-canvas pass is 0.50 s — about
    /// 20 ms a megapixel. Nothing else bounds a chain of them, and every
    /// other op in this family refuses an over-budget call with a sentence
    /// naming the limit, so this one does too: a hundred megapixels is ~2 s,
    /// inside the budget a blocking call is allowed.
    ///
    /// It cannot bind on a real detection — Vision's eye radius comes from
    /// the face it found, so twenty eyes on a 48-megapixel photograph are a
    /// few megapixels between them — and it is deliberately generous for the
    /// explicit list, whose `radius` is easy to give in the wrong unit: 64
    /// discs of radius 1000 on a 5000 x 5000 canvas are 64 whole-canvas
    /// passes, 32 s of frozen main thread, and the schema's own wording
    /// ("it is the IRIS radius") makes that an ordinary mistake rather than a
    /// hostile one.
    static let maxCorrectedPixels: Double = 100_000_000

    /// nil when `eyes` fit [`maxCorrectedPixels`] over a canvas of `size`;
    /// otherwise the sentence to refuse with, naming both numbers. The area
    /// counted is each rect CLIPPED to the canvas, which is what the core
    /// actually scans.
    static func overCorrectionBudget(_ eyes: [Eye], canvas: CGSize) -> String? {
        let bounds = CGRect(origin: .zero, size: canvas)
        let total = eyes.reduce(0.0) { sum, eye in
            let clipped = eye.rect.intersection(bounds)
            return sum + (clipped.isNull ? 0 : Double(clipped.width * clipped.height))
        }
        guard total > maxCorrectedPixels else { return nil }
        let megapixels = { (v: Double) in String(format: "%.0f", v / 1_000_000) }
        return "the \(eyes.count) eyes cover \(megapixels(total)) megapixels of picture between "
            + "them; red-eye correction scans every pixel of each eye's rectangle — a square "
            + "six times the radius — and is limited to \(megapixels(maxCorrectedPixels)) "
            + "megapixels in one call. radius is the IRIS radius in canvas px, so check it is "
            + "not far larger than an eye, or correct the eyes in separate calls."
    }

    /// Why an automatic pass found nothing. Each carries its own sentence:
    /// "no face" and "no eyes" are different answers and the user gets told
    /// which, never a silent no-op. SubjectSelection.Failure's shape exactly,
    /// down to splitting the two the way that one splits `.noSubject` from
    /// `.unreadableMask`.
    enum Failure: Error {
        case noComposite
        case noFace
        case noEyes
        case vision(String)

        var message: String {
            switch self {
            case .noComposite:
                return "The document could not be flattened for face detection."
            case .noFace:
                return "No face was found in the image."
            case .noEyes:
                return "A face was found, but its eyes could not be located."
            case .vision(let reason):
                return "Face detection failed: \(reason)"
            }
        }
    }

    /// Every eye Vision's face landmarks can find in `image`, in canvas
    /// coordinates. Stateless: the menu command and the agent each want one
    /// answer and nothing kept, so unlike SubjectAnalysis there is no cache —
    /// nothing here is hit-tested per mouse event.
    static func eyes(in image: CGImage) throws -> [Eye] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectFaceLandmarksRequest()
        // No orientation argument and no revision pin, exactly as
        // SubjectAnalysis: document pixels are already upright (the core and
        // ImageIO both bake EXIF rotation in at open), and the newest
        // revision is what we want. No #available gate either — the request
        // is macOS 10.13+ and the app's floor is 15. The classic
        // Objective-C request rather than Vision's Swift
        // DetectFaceLandmarksRequest, whose only `perform` is `async`, which
        // app/CLAUDE.md's hygiene rule bans.
        do {
            try handler.perform([request])
        } catch {
            throw Failure.vision(error.localizedDescription)
        }
        // A landmarks request that ran and found nobody returns an EMPTY
        // array, not nil — unlike the segmentation request, which returns no
        // observation at all, hence SubjectAnalysis's `results?.first`.
        let faces = request.results ?? []
        guard !faces.isEmpty else { throw Failure.noFace }

        let size = CGSize(width: image.width, height: image.height)
        var found: [Eye] = []
        for face in faces {
            // nil when only a rectangles request ran: a refusal for this
            // face, not for the picture.
            guard let landmarks = face.landmarks else { continue }
            if let eye = eye(outline: landmarks.leftEye, pupil: landmarks.leftPupil, size: size) {
                found.append(eye)
            }
            if let eye = eye(outline: landmarks.rightEye, pupil: landmarks.rightPupil, size: size)
            {
                found.append(eye)
            }
        }
        guard !found.isEmpty else { throw Failure.noEyes }
        return found
    }

    /// Vision reports landmark points in IMAGE pixels with the origin at the
    /// BOTTOM-left and y growing up; the canvas has row 0 at the top and y
    /// growing down. So the conversion is one subtraction — the mirror of the
    /// flip Bitmap applies to its contexts, and the reason no other
    /// coordinate anywhere in this feature needs thinking about.
    /// `pointsInImage` and never `normalizedPoints`: a region's normalized
    /// points are relative to the FACE BOUNDING BOX, not to the image, so
    /// they would land a fraction of a face away from the eye.
    private static func canvasPoints(
        _ region: VNFaceLandmarkRegion2D, _ size: CGSize
    ) -> [CGPoint] {
        region.pointsInImage(imageSize: size).map {
            CGPoint(x: $0.x, y: size.height - $0.y)
        }
    }

    /// One eye's disc. nil when the region is missing or carries no points —
    /// `pointCount` is documented as possibly zero when a region could not be
    /// located, so the arrays are never indexed blind.
    private static func eye(
        outline: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?, size: CGSize
    ) -> Eye? {
        guard let outline = outline, outline.pointCount > 0 else { return nil }
        let points = canvasPoints(outline, size)
        guard !points.isEmpty else { return nil }
        let center: CGPoint
        if let pupil = pupil, pupil.pointCount > 0,
            let point = canvasPoints(pupil, size).first {
            center = point
        } else {
            // The pupil point is documented as unreliable on a blink; the
            // outline's centroid is not, and it is what the radius already
            // comes from.
            let n = CGFloat(points.count)
            center = CGPoint(
                x: points.reduce(0) { $0 + $1.x } / n,
                y: points.reduce(0) { $0 + $1.y } / n)
        }
        return Eye(center: center, radius: radius(outline: points))
    }

    /// The correction radius, from the eye OUTLINE rather than the pupil
    /// point, which Vision gives as a position and no size.
    ///
    /// The outline's widest chord is the palpebral fissure, and anthropometry
    /// puts the iris at about 40 % of that length — so the iris RADIUS is a
    /// fifth of it. The disc is deliberately the iris and not the pupil:
    /// flash red bleeds past the pupil edge, and the core's redness test is
    /// what actually decides which pixels move (sclera and skin score zero),
    /// so a generous disc costs nothing while a mean one leaves a red rim.
    /// The widest chord rather than the bounding box because it is
    /// rotation-invariant — a rolled head shrinks the axis-aligned box — and
    /// because a blink collapses the eyelid's height while leaving the
    /// corners exactly where they are. The 2 px floor keeps a face a few
    /// dozen pixels wide from producing a degenerate rect.
    private static func radius(outline points: [CGPoint]) -> CGFloat {
        var widest: CGFloat = 0
        // pointCount is 6 (the 65-point constellation) or 8 (the 76-point
        // one), so the quadratic is at most 28 comparisons.
        for (index, a) in points.enumerated() {
            for b in points[(index + 1)...] {
                widest = max(widest, hypot(a.x - b.x, a.y - b.y))
            }
        }
        return max(2, widest * 0.2)
    }
}

extension RasterDocument {
    /// Eyes over the FLATTENED composite — detection reads what the user
    /// sees rather than the active layer, the same choice `subjectMask` and
    /// the magic wand make about where to sample.
    func redEyes() throws -> [RedEye.Eye] {
        // Tagged with the document's own space and converted nowhere: Vision
        // reads the tag and normalizes internally, so handing it sRGB-tagged
        // wide-gamut numbers would show the detector colours the picture
        // never had (the phase-4 rule — a sampled colour converts nowhere).
        guard let composite = flattened()?.makeCGImage(in: colorSpace) else {
            throw RedEye.Failure.noComposite
        }
        return try RedEye.eyes(in: composite)
    }
}
