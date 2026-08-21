import CoreGraphics

/// One rendered stroke vertex: a position on the smoothed path and the
/// interpolated tablet pressure there (1 everywhere for mouse strokes).
struct StrokeVertex {
    var point: CGPoint
    var pressure: CGFloat
}

/// The pulled-string stabilizer behind the paint tools' Smoothing option:
/// the brush position trails the cursor at the end of a rigid leash
/// `radius` px long (canvas px, derived from a screen-space length so the
/// damping matches hand jitter at any zoom). Movement smaller than the
/// leash never reaches the stroke; radius 0 is the identity. Mouse-up
/// feeds the raw cursor once more, so the stroke catches up to where the
/// hand actually stopped.
struct StrokeLeash {
    var position: CGPoint
    var radius: CGFloat

    /// The brush position after the cursor moved to `cursor`.
    mutating func pull(toward cursor: CGPoint) -> CGPoint {
        let dx = cursor.x - position.x
        let dy = cursor.y - position.y
        let distance = hypot(dx, dy)
        guard distance > radius, distance > 0 else { return position }
        let k = (distance - radius) / distance
        position = CGPoint(x: position.x + dx * k, y: position.y + dy * k)
        return position
    }
}

/// Smooths an interactive stroke. AppKit coalesces drag events to roughly
/// one per display frame, so a fast flick leaves long gaps between samples
/// — and straight chords render those gaps as a polygon. This collects the
/// samples and re-emits the stroke as centripetal Catmull-Rom spans: each
/// span interpolates its two middle samples exactly, steered by the outer
/// two, so rendering runs one sample behind the cursor and `finish`
/// flushes the tail at mouse-up. Centripetal knots (α = ½) rather than
/// uniform, because flick gaps are wildly uneven — exactly where uniform
/// Catmull-Rom overshoots and loops.
///
/// Spans come back flattened to sub-facet straight steps, which both
/// stroke pipelines already consume: the hard path strokes them with the
/// round joins in its gstate, the dab walk stamps along them carrying its
/// spacing. Each vertex also carries tablet pressure, interpolated
/// linearly across its span (position deserves a spline; a scalar does
/// not). Canvas strokes only — agent strokes are deliberate geometry,
/// rendered as the exact polyline the caller sent.
struct StrokeSpline {
    /// The sliding control window: the last four accepted samples (fewer
    /// while the stroke is young).
    private var window: [(point: CGPoint, pressure: CGFloat)] = []

    /// Starts over at the stroke's first point.
    mutating func begin(at point: CGPoint, pressure: CGFloat = 1) {
        window = [(point, pressure)]
    }

    /// Feeds the next drag sample. Returns the vertices newly safe to
    /// render — the span ending one sample back, whose exit tangent this
    /// sample just fixed — or nothing while the window is still filling.
    /// A stationary sample is dropped (it adds no geometry and would
    /// collapse a knot interval); a pressure change with no motion is
    /// deliberately dropped with it.
    mutating func add(_ point: CGPoint, pressure: CGFloat = 1) -> [StrokeVertex] {
        guard let last = window.last,
              hypot(point.x - last.point.x, point.y - last.point.y) > 0.001
        else { return [] }
        window.append((point, pressure))
        if window.count > 4 { window.removeFirst() }
        switch window.count {
        case 3:
            // The first span has no sample before its anchor; the anchor
            // doubles, which flattens the entry tangent (and is exact —
            // a doubled control collapses out of the evaluation).
            return Self.flatten(window[0], window[0], window[1], window[2])
        case 4:
            return Self.flatten(window[0], window[1], window[2], window[3])
        default:
            return []
        }
    }

    /// The tail span, held back until now for want of an exit tangent —
    /// the final sample doubles for it. Mouse-up renders this and the
    /// stroke is complete; the window resets for the next stroke.
    mutating func finish() -> [StrokeVertex] {
        defer { window = [] }
        switch window.count {
        case 2:
            return Self.flatten(window[0], window[0], window[1], window[1])
        case 3:
            return Self.flatten(window[0], window[1], window[2], window[2])
        case 4:
            return Self.flatten(window[1], window[2], window[3], window[3])
        default:
            return []
        }
    }

    /// One span — `b` to `c`, steered by `a` and `d` — flattened to steps
    /// short enough that neither pipeline can show a facet. The returned
    /// vertices exclude `b` (the previous span, or the start dab, already
    /// rendered through it) and end on `c` exactly, so spans chain with no
    /// drift. Pressure runs linearly from `b`'s to `c`'s.
    private static func flatten(
        _ a: (point: CGPoint, pressure: CGFloat),
        _ b: (point: CGPoint, pressure: CGFloat),
        _ c: (point: CGPoint, pressure: CGFloat),
        _ d: (point: CGPoint, pressure: CGFloat)
    ) -> [StrokeVertex] {
        let (a, b1p, c1p, d) = (a.point, b, c, d.point)
        let (b, c) = (b1p.point, c1p.point)
        let chord = hypot(c.x - b.x, c.y - b.y)
        guard chord > 0.001 else { return [] }
        // ~1.5 px steps, capped: past the cap the facets grow, but a span
        // that long is a >100 px inter-frame gap, where round joins at
        // stroke width hide them regardless.
        let steps = Int(min(96, max(1, (chord / 1.5).rounded(.up))))
        // Centripetal knot intervals grow with √distance, floored so the
        // doubled controls of the first and last spans cannot zero one
        // (a zero interval would divide by zero below).
        let t0: CGFloat = 0
        let t1 = t0 + max(sqrt(hypot(b.x - a.x, b.y - a.y)), 0.001)
        let t2 = t1 + max(sqrt(chord), 0.001)
        let t3 = t2 + max(sqrt(hypot(d.x - c.x, d.y - c.y)), 0.001)
        var vertices: [StrokeVertex] = []
        vertices.reserveCapacity(steps)
        for i in 1...steps {
            let fraction = CGFloat(i) / CGFloat(steps)
            let pressure = b1p.pressure + (c1p.pressure - b1p.pressure) * fraction
            guard i < steps else {
                vertices.append(StrokeVertex(point: c, pressure: c1p.pressure))
                break
            }
            let t = t1 + (t2 - t1) * fraction
            // Barry–Goldman's pyramid: three lerps between neighbors, two
            // between those, one at the top. A doubled control makes some
            // weights huge, but always against a zero difference — the
            // lerp still lands exactly on the doubled point.
            func mix(_ p: CGPoint, _ q: CGPoint, _ ta: CGFloat, _ tb: CGFloat) -> CGPoint {
                let w = (t - ta) / (tb - ta)
                return CGPoint(x: p.x + (q.x - p.x) * w, y: p.y + (q.y - p.y) * w)
            }
            let a1 = mix(a, b, t0, t1)
            let a2 = mix(b, c, t1, t2)
            let a3 = mix(c, d, t2, t3)
            let b1 = mix(a1, a2, t0, t2)
            let b2 = mix(a2, a3, t1, t3)
            vertices.append(StrokeVertex(point: mix(b1, b2, t1, t2), pressure: pressure))
        }
        return vertices
    }
}
