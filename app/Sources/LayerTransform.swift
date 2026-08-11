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

    /// Scale magnitudes are clamped away from zero (a zero scale is a
    /// singular matrix, which the core refuses) and away from absurd
    /// enlargements (which would blow past the core's pixel ceiling).
    static let minScaleMagnitude: CGFloat = 0.001
    static let maxScaleMagnitude: CGFloat = 100

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

    /// True when the composed matrix is the identity: nothing moved, so a
    /// commit must register no edit at all.
    var isIdentity: Bool {
        let m = matrix
        return abs(m.a - 1) < 1e-9 && abs(m.b) < 1e-9 && abs(m.c) < 1e-9
            && abs(m.d - 1) < 1e-9 && abs(m.tx) < 1e-6 && abs(m.ty) < 1e-6
    }

    /// True when every parameter is finite — the matrix a NaN would compose
    /// is one the core rejects, so the session refuses to build it.
    var isFinite: Bool {
        pivot.x.isFinite && pivot.y.isFinite && translation.dx.isFinite
            && translation.dy.isFinite && angle.isFinite && scaleX.isFinite && scaleY.isFinite
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

        let handlePoint = handle.point(in: rect)
        let anchorPoint = handle.opposite.point(in: rect)
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
        let points = quad(of: rect)
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
}
