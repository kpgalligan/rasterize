import AppKit

/// The agent's red-eye pair, mirroring both UI paths: `red_eye` is the Red
/// Eye tool's drag rectangle (EditorViewController+RedEye.redEyeRectDragged)
/// and `red_eye_auto` is Filters > Remove Red Eye
/// (EditorViewController+RedEye.removeRedEye). The correction is the core's
/// `rz_doc_red_eye_layer` in both cases; the detection is RedEye.swift.
extension AgentServer {
    /// red_eye — mirrors the Red Eye tool's drag rectangle: inside it, pixels
    /// are scored by red DOMINANCE and the red is neutralised and darkened,
    /// with a size gate that spares anything bigger than an eye. One undo
    /// step.
    ///
    /// The rectangle is the whole domain, so — like the tool — this does NOT
    /// confine itself to the active selection: there is no mask in the op's
    /// signature and a rectangle over one eye is already as confined as a
    /// selection would make it.
    func redEye(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        // The UI refuses a red-eye commit on an adjustment layer outright
        // (redEyeRectDragged's refuseAdjustmentPixelEdit): there are no
        // pixels to rewrite.
        try rejectAdjustmentPixelEdit(document, index)
        let rect = try redEyeRect(a)
        let (pupilSize, darken) = try redEyeDials(a)

        let rasterized: DroppedDescription?
        // Latched when the CORE OP answers nil, so only that case reads as a
        // no-op — any other failure stays an error.
        var opRefused = false
        do {
            rasterized = try performPixelEdit(document, "Remove Red Eye", pixelLayer: index) {
                current in
                let out = current.redEyeLayer(
                    index, rect: rect, pupilSize: pupilSize, darken: darken)
                if out == nil { opRefused = true }
                return out
            }
        } catch let error as ToolError {
            guard opRefused else { throw error }
            // Four different nothings, and the model can act on the
            // difference: nothing red, nothing small enough, red that fills
            // the rectangle, or a rectangle that missed the layer. No edit
            // landed, no undo step opened.
            return try jsonResult([
                "ok": true, "changed": false, "layer": index,
                "note": "Nothing changed: the rectangle holds no flash red, every red region "
                    + "in it is larger than pupil_size "
                    + "(\(String(format: "%g", pupilSize * 100))% of the rectangle's shorter "
                    + "side) allows, every red region in it reaches all four sides of the "
                    + "rectangle (put the rectangle around an eye, not inside something red), "
                    + "or it never reached layer \(index)'s pixels. No undo "
                    + "step was added.",
            ])
        }
        return try pixelEditResult(
            [
                "ok": true, "action": "Remove Red Eye", "layer": index,
                "rect": [
                    "x": Self.transformNumber(Double(rect.minX)),
                    "y": Self.transformNumber(Double(rect.minY)),
                    "width": Self.transformNumber(Double(rect.width)),
                    "height": Self.transformNumber(Double(rect.height)),
                ],
                "applied": [
                    "pupil_size": Self.transformNumber(pupilSize * 100),
                    "darken": Self.transformNumber(darken * 100),
                ],
            ], layer: index, rasterized: rasterized)
    }

    /// red_eye_auto — mirrors Filters > Remove Red Eye: Vision's face
    /// landmarks locate every eye in the flattened composite and the same
    /// correction runs on each of them, chained into ONE undo step.
    ///
    /// An explicit `eyes` list skips Vision entirely — `select_subject`'s
    /// `instance` trick in another shape. It is what makes the pipeline
    /// drivable end to end on a picture with no face in it (there is none in
    /// this repo), and it is the model's repair path when the detector
    /// misses an eye.
    func redEyeAuto(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        // The UI's menu item is disabled on an adjustment layer for the same
        // reason (validateUserInterfaceItem, removeRedEye's case).
        try rejectAdjustmentPixelEdit(document, index)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let (pupilSize, darken) = try redEyeDials(a)
        let explicit = try explicitEyes(a)
        let eyes: [RedEye.Eye]
        if let explicit = explicit {
            eyes = explicit
        } else {
            do {
                eyes = try doc.redEyes()
            } catch let failure as RedEye.Failure {
                // In-band, like every other handler failure, so the model
                // reads "No face was found in the image." and switches to
                // red_eye with a rectangle rather than seeing a transport
                // error. Never a modal on an agent path.
                throw ToolError(
                    message: failure.message
                        + " Use red_eye with a rectangle over the eye, or pass eyes "
                        + "explicitly to skip detection.")
            }
        }

        // Every eye is a full pass over its own rectangle, chained inside one
        // edit, so what has to be bounded is the TOTAL area — the one
        // quantity the ±100,000 px wall on a single radius and the 64-entry
        // wall on the list leave unbounded between them. RedEye owns the
        // number and the sentence; see `maxCorrectedPixels`.
        if let message = RedEye.overCorrectionBudget(
            eyes, canvas: CGSize(width: doc.width, height: doc.height)) {
            throw ToolError(message: message)
        }

        var corrected = 0
        let rasterized: DroppedDescription?
        // The same latch, for the other nothing: the eyes were found and none
        // of them held any red.
        var opRefused = false
        do {
            rasterized = try performPixelEdit(document, "Remove Red Eye", pixelLayer: index) {
                current in
                // §0.7(b): chained per eye, and nil rather than the input
                // handle when nothing moved — performGroupedEdit does not
                // compare handles, so returning `out` unchanged would mint an
                // undo step and a dirty flag for an edit that did nothing.
                var out = current
                for eye in eyes {
                    if let next = out.redEyeLayer(
                        index, rect: eye.rect, pupilSize: pupilSize, darken: darken) {
                        out = next
                        corrected += 1
                    }
                }
                guard out !== current else {
                    opRefused = true
                    return nil
                }
                return out
            }
        } catch let error as ToolError {
            guard opRefused else { throw error }
            return try jsonResult([
                "ok": true, "changed": false, "layer": index, "eyes": eyes.count,
                "corrected": 0,
                "note": "Nothing changed: \(eyes.count) "
                    + (eyes.count == 1 ? "eye was" : "eyes were")
                    + " located, but none of them holds flash red on layer \(index) — the "
                    + "picture may already be corrected, or the eyes may be on another "
                    + "layer. No undo step was added.",
            ])
        }
        return try pixelEditResult(
            [
                "ok": true, "action": "Remove Red Eye", "layer": index,
                "eyes": eyes.count, "corrected": corrected,
                "detection": explicit == nil ? "vision" : "explicit",
                "applied": [
                    "pupil_size": Self.transformNumber(pupilSize * 100),
                    "darken": Self.transformNumber(darken * 100),
                ],
            ], layer: index, rasterized: rasterized)
    }

    // MARK: - Arguments

    /// The drag rectangle in canvas pixels. Required, because a red-eye
    /// correction without one would be a whole-image colour test, which is
    /// exactly what the core refuses to offer (lipstick and a red shirt score
    /// like a pupil — only geometry tells them apart).
    private func redEyeRect(_ a: [String: Any]) throws -> CGRect {
        guard let x = doubleArg(a, "x"), let y = doubleArg(a, "y"),
            let width = doubleArg(a, "width"), let height = doubleArg(a, "height")
        else {
            throw ToolError(
                message: "red_eye requires x, y, width and height — the rectangle to look for "
                    + "flash red inside, in canvas px. Drag it tight around ONE eye.")
        }
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            throw ToolError(message: "x, y, width and height must be finite numbers")
        }
        guard width >= 1, height >= 1 else {
            throw ToolError(message: "width and height must be at least 1 px")
        }
        // The same ±100,000 px wall `parsePoints` puts on a stroke coordinate
        // and `patch_region` on an offset. Here it is not only tidiness: the
        // rect reaches `RasterDocument.redEyeLayer`, which has to turn it
        // into pixel integers, and a refusal with a sentence in it is a
        // better answer to a scientific-notation coordinate than a silent
        // clamp to the edge of the addressable canvas.
        guard abs(x) <= 100_000, abs(y) <= 100_000, width <= 100_000, height <= 100_000
        else {
            throw ToolError(
                message: "x, y, width and height must be within ±100,000 canvas px — got "
                    + "(\(x), \(y)) \(width) x \(height). Put the rectangle around an eye "
                    + "in the picture.")
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `pupil_size` and `darken`, both percentages in the schema and
    /// fractions in the core. The defaults are the tool's own: 100 % (the
    /// gate exists to reject something BIGGER than an eye) and 50 %
    /// (Photoshop's darkening).
    private func redEyeDials(_ a: [String: Any]) throws -> (pupilSize: Double, darken: Double) {
        let pupil = doubleArg(a, "pupil_size") ?? 100
        guard pupil.isFinite, pupil >= 1, pupil <= 100 else {
            throw ToolError(
                message: "pupil_size must be between 1 and 100 (percent of the rectangle's "
                    + "shorter side)")
        }
        let darken = doubleArg(a, "darken") ?? 50
        guard darken.isFinite, darken >= 0, darken <= 100 else {
            throw ToolError(message: "darken must be between 0 and 100 (percent)")
        }
        return (pupil / 100, darken / 100)
    }

    /// The optional explicit `eyes` list: `{x, y, radius}` discs in canvas
    /// coordinates, turned into the very same `RedEye.Eye` values Vision
    /// produces — so both paths hand the core the identical rectangle (a
    /// square of side 6 · radius, RedEye.Eye.rect) and behave identically.
    /// nil when the argument is absent, which is what selects the detector.
    private func explicitEyes(_ a: [String: Any]) throws -> [RedEye.Eye]? {
        guard let raw = a["eyes"] else { return nil }
        guard let list = raw as? [[String: Any]] else {
            throw ToolError(
                message: "eyes must be an array of objects with x, y and radius (canvas px)")
        }
        guard !list.isEmpty else {
            throw ToolError(message: "eyes was empty — omit it to detect the eyes instead")
        }
        guard list.count <= 64 else {
            throw ToolError(message: "eyes takes at most 64 discs (got \(list.count))")
        }
        return try list.map { entry in
            guard let x = doubleArg(entry, "x"), let y = doubleArg(entry, "y"),
                let radius = doubleArg(entry, "radius")
            else {
                throw ToolError(message: "each entry in eyes needs x, y and radius")
            }
            guard x.isFinite, y.isFinite, radius.isFinite, radius > 0 else {
                throw ToolError(
                    message: "each eye's x and y must be finite and radius must be positive "
                        + "— it is the IRIS radius in canvas px, and the correction runs "
                        + "inside a square three times that radius on each side.")
            }
            // `redEyeRect`'s wall, on the values that build the same rect:
            // `RedEye.Eye.rect` is a square of side 6 · radius, so an
            // unbounded radius is an unbounded rectangle by another route.
            guard abs(x) <= 100_000, abs(y) <= 100_000, radius <= 100_000 else {
                throw ToolError(
                    message: "each eye's x, y and radius must be within ±100,000 canvas px "
                        + "— got (\(x), \(y)) radius \(radius).")
            }
            return RedEye.Eye(center: CGPoint(x: x, y: y), radius: CGFloat(radius))
        }
    }
}
