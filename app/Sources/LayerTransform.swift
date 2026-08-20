import AppKit

/// One of the eight handles of a free-transform box, named for its position
/// in the layer's OWN (untransformed) canvas rect. The canvas is flipped, so
/// "top" is the smaller y — exactly what it looks like on screen.
enum TransformHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    /// The handle's position in the unit square measured from the rect's
    /// centre: -1, 0 or +1 on each axis.
    var unit: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: -1, y: -1)
        case .top: return CGPoint(x: 0, y: -1)
        case .topRight: return CGPoint(x: 1, y: -1)
        case .right: return CGPoint(x: 1, y: 0)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottom: return CGPoint(x: 0, y: 1)
        case .bottomLeft: return CGPoint(x: -1, y: 1)
        case .left: return CGPoint(x: -1, y: 0)
        }
    }

    /// The handle across the box, which a plain (no-Option) scale drag pins.
    var opposite: TransformHandle {
        switch self {
        case .topLeft: return .bottomRight
        case .top: return .bottom
        case .topRight: return .bottomLeft
        case .right: return .left
        case .bottomRight: return .topLeft
        case .bottom: return .top
        case .bottomLeft: return .topRight
        case .left: return .right
        }
    }

    /// The four corners drive BOTH axes; the edge midpoints drive one.
    var isCorner: Bool { unit.x != 0 && unit.y != 0 }

    /// The warped-quad corner indices this handle derives from — one for a
    /// corner handle, the edge's two for a midpoint — in the quad order
    /// TL, TR, BR, BL.
    var quadCorners: [Int] {
        switch self {
        case .topLeft: return [0]
        case .top: return [0, 1]
        case .topRight: return [1]
        case .right: return [1, 2]
        case .bottomRight: return [2]
        case .bottom: return [2, 3]
        case .bottomLeft: return [3]
        case .left: return [3, 0]
        }
    }

    /// Where the handle sits on `rect`, in the rect's own (canvas) space.
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.midX + unit.x * rect.width / 2,
            y: rect.midY + unit.y * rect.height / 2)
    }
}

/// The parameters a free-transform session edits over a layer's ORIGINAL
/// canvas-space rect. The PARAMETERS are the source of truth and the matrix
/// is composed from them on demand — nothing here ever decomposes a matrix
/// back into parameters, so handle drags and the options-bar numerics are two
/// views of one state instead of two sources of rounding error.
///
/// The composition, in CANVAS coordinates, is
///
///     translate(pivot) · translate(translation) · rotate(angle)
///         · scale(scaleX, scaleY) · translate(-pivot)
///
/// which is exactly the matrix `rz_doc_transform_layer` takes (canvas space,
/// CGAffineTransform element order). Canvas y grows downward, so a positive
/// angle reads as CLOCKWISE on screen.
struct LayerTransform {
    /// The fixed point of rotation and scaling, in canvas coordinates
    /// (the layer rect's centre for the whole of a session).
    var pivot: CGPoint
    /// Canvas-space offset applied after the pivot-centred rotate/scale.
    var translation: CGVector = .zero
    /// Clockwise rotation in RADIANS.
    var angle: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    /// Per-corner displacements in the layer's own SOURCE space, in quad
    /// order TL, TR, BR, BL — the distort/perspective stage. A warped
    /// corner is `matrix.apply(rectCorner + offset)`: the offsets ride
    /// INSIDE the affine, so moving, rotating and scaling carry a warped
    /// box rigidly along, and the affine parameters stay exactly what the
    /// options-bar numerics bind to.
    var cornerOffsets: [CGVector] = [.zero, .zero, .zero, .zero]

    /// Scale magnitudes are clamped away from zero (a zero scale is a
    /// singular matrix, which the core refuses) and away from absurd
    /// enlargements (which would blow past the core's pixel ceiling).
    static let minScaleMagnitude: CGFloat = 0.001
    static let maxScaleMagnitude: CGFloat = 100

    /// The core's extent ceiling (`MAX_PIXELS`, restated in the header) —
    /// the one Swift home for the number, mirrored by the agent's
    /// pre-checks and the distort drag clamp.
    static let maxTransformPixels: Double = 100_000_000

    /// Below anything a drag can mean (a millionth of a pixel), so a
    /// corner pulled exactly back onto its start commits as the plain
    /// affine it is.
    static let cornerEpsilon: CGFloat = 1e-6

    init(pivot: CGPoint) {
        self.pivot = pivot
    }

    /// The composed canvas-space matrix. `CGAffineTransform`'s builder
    /// methods pre-multiply, so this reads in the same order as the formula
    /// above: the last line is applied to a source point first.
    var matrix: CGAffineTransform {
        var t = CGAffineTransform(
            translationX: pivot.x + translation.dx, y: pivot.y + translation.dy)
        t = t.rotated(by: angle)
        t = t.scaledBy(x: scaleX, y: scaleY)
        return t.translatedBy(x: -pivot.x, y: -pivot.y)
    }

    /// Where the pivot itself lands — the point every rotation turns around
    /// and every scale grows from.
    var pivotInCanvas: CGPoint {
        CGPoint(x: pivot.x + translation.dx, y: pivot.y + translation.dy)
    }

    /// The rotation in degrees, clockwise, normalized to (-180, 180].
    var degrees: Double {
        get { Double(angle) * 180 / .pi }
        set { angle = Self.normalized(CGFloat(newValue) * .pi / 180) }
    }

    /// True when any corner is displaced by more than [`cornerEpsilon`] —
    /// the commit must then take the perspective path.
    var hasCornerOffsets: Bool {
        cornerOffsets.contains {
            abs($0.dx) > Self.cornerEpsilon || abs($0.dy) > Self.cornerEpsilon
        }
    }

    /// True when the composed matrix is the identity and no corner is
    /// displaced: nothing moved, so a commit must register no edit at all.
    var isIdentity: Bool {
        guard !hasCornerOffsets else { return false }
        let m = matrix
        return abs(m.a - 1) < 1e-9 && abs(m.b) < 1e-9 && abs(m.c) < 1e-9
            && abs(m.d - 1) < 1e-9 && abs(m.tx) < 1e-6 && abs(m.ty) < 1e-6
    }

    /// True when every parameter is finite — the matrix a NaN would compose
    /// is one the core rejects, so the session refuses to build it.
    var isFinite: Bool {
        pivot.x.isFinite && pivot.y.isFinite && translation.dx.isFinite
            && translation.dy.isFinite && angle.isFinite && scaleX.isFinite && scaleY.isFinite
            && cornerOffsets.allSatisfy { $0.dx.isFinite && $0.dy.isFinite }
    }

    // MARK: - Gestures (parameters in, parameters out)

    /// `start` moved by `delta` (canvas space). Shift — `constrained` —
    /// keeps the move on one axis.
    static func moving(_ start: LayerTransform, by delta: CGVector, constrained: Bool)
        -> LayerTransform
    {
        var result = start
        var delta = delta
        if constrained {
            if abs(delta.dx) >= abs(delta.dy) {
                delta.dy = 0
            } else {
                delta.dx = 0
            }
        }
        result.translation = CGVector(
            dx: start.translation.dx + delta.dx, dy: start.translation.dy + delta.dy)
        return result
    }

    /// `start` turned so the grab point follows the pointer around the
    /// pivot. Shift — `snap` — quantizes the RESULT to 15° increments.
    static func rotating(
        _ start: LayerTransform, from grab: CGPoint, to point: CGPoint, snap: Bool
    ) -> LayerTransform {
        var result = start
        let origin = start.pivotInCanvas
        let from = atan2(grab.y - origin.y, grab.x - origin.x)
        let to = atan2(point.y - origin.y, point.x - origin.x)
        var angle = start.angle + (to - from)
        if snap {
            let step = CGFloat.pi / 12 // 15°
            angle = (angle / step).rounded() * step
        }
        result.angle = normalized(angle)
        return result
    }

    /// `start` rescaled so that dragging `handle` — a handle of `rect`, the
    /// layer's original canvas rect — lands it on `point`.
    ///
    /// The default pins the OPPOSITE handle: the scale changes and the
    /// translation absorbs whatever that would have moved. `aboutPivot`
    /// (Option) instead keeps the pivot fixed, so the box grows both ways.
    /// `proportional` (Shift) drives both axes by the single factor the drag
    /// implies, which preserves the box's aspect exactly.
    static func scaling(
        _ start: LayerTransform, in rect: CGRect, handle: TransformHandle, to point: CGPoint,
        proportional: Bool, aboutPivot: Bool
    ) -> LayerTransform {
        var result = start
        let cosine = cos(start.angle)
        let sine = sin(start.angle)
        // The pointer in the box's OWN (unrotated) axes, relative to the
        // pivot: R(-angle) · (point - pivotInCanvas).
        let origin = start.pivotInCanvas
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let local = CGPoint(x: dx * cosine + dy * sine, y: -dx * sine + dy * cosine)

        // Offset-adjusted source points: on a warped box the VISIBLE handle
        // is the mapped, corner-offset point, and solving against it keeps
        // that handle under the pointer (and the visible anchor pinned)
        // instead of jumping by matrix·offset. Zero offsets reduce these to
        // the plain rect corners/midpoints.
        let handlePoint = start.sourceHandlePoint(handle, of: rect)
        let anchorPoint = start.sourceHandlePoint(handle.opposite, of: rect)
        // Source-space offsets: of the handle from the pivot, of the anchor
        // from the pivot, and of the handle from the anchor.
        let fromPivot = CGPoint(
            x: handlePoint.x - start.pivot.x, y: handlePoint.y - start.pivot.y)
        let anchorFromPivot = CGPoint(
            x: anchorPoint.x - start.pivot.x, y: anchorPoint.y - start.pivot.y)
        let span = CGPoint(
            x: handlePoint.x - anchorPoint.x, y: handlePoint.y - anchorPoint.y)

        var scaleX = start.scaleX
        var scaleY = start.scaleY
        var drivesX = false
        var drivesY = false
        if aboutPivot {
            // scale' · fromPivot = local
            if fromPivot.x != 0 {
                scaleX = local.x / fromPivot.x
                drivesX = true
            }
            if fromPivot.y != 0 {
                scaleY = local.y / fromPivot.y
                drivesY = true
            }
        } else {
            // scale' · span = local - scale · anchorFromPivot
            if span.x != 0 {
                scaleX = (local.x - start.scaleX * anchorFromPivot.x) / span.x
                drivesX = true
            }
            if span.y != 0 {
                scaleY = (local.y - start.scaleY * anchorFromPivot.y) / span.y
                drivesY = true
            }
        }

        if proportional {
            // One factor for both axes, taken from the axis that moved most
            // (an edge handle only drives one, so it simply wins).
            let factorX = (drivesX && start.scaleX != 0) ? scaleX / start.scaleX : nil
            let factorY = (drivesY && start.scaleY != 0) ? scaleY / start.scaleY : nil
            var factor: CGFloat?
            switch (factorX, factorY) {
            case let (x?, y?): factor = abs(x) >= abs(y) ? x : y
            case let (x?, nil): factor = x
            case let (nil, y?): factor = y
            default: factor = nil
            }
            if let factor = factor {
                scaleX = start.scaleX * factor
                scaleY = start.scaleY * factor
            }
        }

        result.scaleX = clampScale(scaleX)
        result.scaleY = clampScale(scaleY)
        if !aboutPivot {
            // The anchor is pinned: whatever the scale change moved it by
            // (in the box's own axes, rotated back into canvas space) is
            // taken out of the translation.
            let shift = CGPoint(
                x: (start.scaleX - result.scaleX) * anchorFromPivot.x,
                y: (start.scaleY - result.scaleY) * anchorFromPivot.y)
            result.translation = CGVector(
                dx: start.translation.dx + shift.x * cosine - shift.y * sine,
                dy: start.translation.dy + shift.x * sine + shift.y * cosine)
        }
        return result
    }

    /// `start` with `corner` (a quad index, TL 0 … BL 3) dragged so its
    /// warped position lands on `point`. The pointer is pulled back through
    /// the affine — always invertible, `clampScale` keeps scales off zero —
    /// into the source space the offsets live in. A drag that would make
    /// the quad non-convex (the fold the core refuses), nearly collapse
    /// it, or blow the destination extent past the core's caps sticks at
    /// `start` instead: like `clampScale`, the session must never hold a
    /// transform the commit would refuse.
    static func distorting(
        _ start: LayerTransform, corner: Int, to point: CGPoint, in rect: CGRect
    ) -> LayerTransform {
        guard (0..<4).contains(corner), point.x.isFinite, point.y.isFinite else { return start }
        let source = point.applying(start.matrix.inverted())
        let base = Self.rectCorners(rect)[corner]
        var result = start
        result.cornerOffsets[corner] = CGVector(dx: source.x - base.x, dy: source.y - base.y)
        let quad = result.warpedQuad(of: rect)
        guard result.isFinite, Self.isUsableQuad(quad),
              Self.extentIsCommittable(Self.boundingExtent(of: quad))
        else { return start }
        return result
    }

    /// `rect`'s corners in quad order (TL, TR, BR, BL on the y-down
    /// canvas) — the order `CGAffineTransform.quad(of:)`, `cornerOffsets`
    /// and the core's `rz_doc_perspective_layer` all share.
    static func rectCorners(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    /// The four canvas corners the layer's rect lands on: rect corner plus
    /// its source-space offset, through the matrix. With zero offsets this
    /// is `matrix.quad(of: rect)`.
    func warpedQuad(of rect: CGRect) -> [CGPoint] {
        let m = matrix
        return zip(Self.rectCorners(rect), cornerOffsets).map {
            CGPoint(x: $0.x + $1.dx, y: $0.y + $1.dy).applying(m)
        }
    }

    /// Where `handle` sits in SOURCE space with the corner offsets applied:
    /// a corner plus its offset, an edge handle the average of its two.
    /// With zero offsets this is exactly `handle.point(in: rect)`. It is
    /// the source-space preimage of `warpedHandlePoint`, and what `scaling`
    /// solves against so a drag keeps the VISIBLE handle under the pointer.
    func sourceHandlePoint(_ handle: TransformHandle, of rect: CGRect) -> CGPoint {
        let corners = Self.rectCorners(rect)
        let indices = handle.quadCorners
        let sum = indices.reduce(CGPoint.zero) {
            CGPoint(
                x: $0.x + corners[$1].x + cornerOffsets[$1].dx,
                y: $0.y + corners[$1].y + cornerOffsets[$1].dy)
        }
        return CGPoint(
            x: sum.x / CGFloat(indices.count), y: sum.y / CGFloat(indices.count))
    }

    /// Where `handle` sits on the warped box — `sourceHandlePoint` through
    /// the matrix. An edge handle lands on the average of its two warped
    /// corners (affine maps commute with averaging), which for a
    /// parallelogram IS the mapped edge midpoint, so unwarped sessions hit
    /// exactly where they always did, and warped ones hit where the box
    /// drawing puts the squares.
    func warpedHandlePoint(_ handle: TransformHandle, of rect: CGRect) -> CGPoint {
        sourceHandlePoint(handle, of: rect).applying(matrix)
    }

    /// The extent the perspective commit will produce — the warped twin of
    /// `destinationExtent(of:)`, rounded exactly the core's way.
    func warpedDestinationExtent(of rect: CGRect) -> CGRect {
        Self.boundingExtent(of: warpedQuad(of: rect))
    }

    /// True when four canvas points form a strictly convex quad (either
    /// winding): every consecutive-edge cross product carries one sign,
    /// above a small area floor. Convexity is the core's fold rule — a
    /// concave or self-intersecting quad is exactly where a corner's
    /// homogeneous w crosses zero — held a hair conservatively so a live
    /// drag stops just before the core would refuse.
    static func isUsableQuad(_ corners: [CGPoint]) -> Bool {
        guard corners.count == 4 else { return false }
        var sign: CGFloat = 0
        for i in 0..<4 {
            let a = corners[i]
            let b = corners[(i + 1) % 4]
            let c = corners[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard cross.isFinite, abs(cross) > 1e-3 else { return false }
            let s: CGFloat = cross > 0 ? 1 : -1
            if sign == 0 {
                sign = s
            } else if s != sign {
                return false
            }
        }
        return true
    }

    /// True when `extent` is one the core will accept: at least a pixel on
    /// each side, offsets inside Int32, area within [`maxTransformPixels`].
    static func extentIsCommittable(_ extent: CGRect) -> Bool {
        extent.width >= 1 && extent.height >= 1
            && extent.minX >= CGFloat(Int32.min) && extent.minY >= CGFloat(Int32.min)
            && extent.maxX <= CGFloat(Int32.max) && extent.maxY <= CGFloat(Int32.max)
            && Double(extent.width) * Double(extent.height) <= Self.maxTransformPixels
    }

    /// The outward-rounded bounding box of `points`, rounded exactly the
    /// way the core rounds a destination extent — the shared tail of
    /// `destinationExtent(of:)` and `warpedDestinationExtent(of:)`.
    static func boundingExtent(of points: [CGPoint]) -> CGRect {
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite
        else { return .zero }
        let x = minX.rounded(.down)
        let y = minY.rounded(.down)
        return CGRect(
            x: x, y: y,
            width: max(maxX.rounded(.up) - x, 0),
            height: max(maxY.rounded(.up) - y, 0))
    }

    /// Keeps a scale usable: finite, non-zero (a singular matrix is refused
    /// by the core) and within the magnitude the extent cap allows.
    static func clampScale(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value != 0 else { return minScaleMagnitude }
        let magnitude = min(max(abs(value), minScaleMagnitude), maxScaleMagnitude)
        return value < 0 ? -magnitude : magnitude
    }

    /// An angle folded into (-π, π].
    static func normalized(_ angle: CGFloat) -> CGFloat {
        guard angle.isFinite else { return 0 }
        var result = angle.truncatingRemainder(dividingBy: .pi * 2)
        if result > .pi { result -= .pi * 2 }
        if result <= -.pi { result += .pi * 2 }
        return result
    }
}

extension CGAffineTransform {
    /// `rect`'s four corners mapped through this matrix, clockwise from the
    /// top-left in the rect's own (canvas) space.
    func quad(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ].map { $0.applying(self) }
    }

    /// The extent `rz_doc_transform_layer` will give the layer: the
    /// axis-aligned bounding box of the transformed corners rounded OUTWARD,
    /// exactly the way the core rounds it, so the options bar can show the
    /// resulting pixel size without asking the core.
    func destinationExtent(of rect: CGRect) -> CGRect {
        LayerTransform.boundingExtent(of: quad(of: rect))
    }
}
