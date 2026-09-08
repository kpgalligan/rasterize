import AppKit

/// The document grid, the pixel lattice and the Smart Guides' drawing.
/// Nothing here reads the document or the options store: it draws the values
/// the controller pushed in (`chrome`) and the lines the solver computed
/// (`smartGuides`), and makes no geometric decisions of its own.
extension ImageCanvasView {

    // MARK: - The numbers, and why each one is that number

    /// The hard ceiling on grid lines per redraw, counting both axes
    /// together.
    ///
    /// It is a loop bound, not an aesthetic: a 0.1 px spacing on a 30000 px
    /// canvas asks for 300000 lines, and the draw would spin at pointer
    /// rate. 4000 is far past anything legible — a 5120-point-wide display
    /// cannot separate more than one line per point in either axis — so by
    /// the time the cap bites, the "grid" is already a flat wash. What the
    /// cap does when it bites is stated at each site: the subdivisions go
    /// first (a major-only grid is still a grid), and a MAJOR grid past the
    /// cap draws nothing at all rather than a wash pretending to measure.
    private static let maxGridLines = 4000

    /// Major lines at 0.30 of the ink, subdivisions at half that. A
    /// measuring aid has to read over a photograph without competing with
    /// it, and the subdivisions being visibly lighter is what keeps the
    /// majors countable at a glance instead of the whole grid reading as one
    /// texture.
    private static let gridMajorAlpha: CGFloat = 0.30
    private static let gridSubdivisionAlpha: CGFloat = 0.15

    /// The pixel lattice is the densest thing this file draws — a line at
    /// every pixel — so it takes the lightest ink of the three. 0.18 sits
    /// just above the subdivision weight, which is what a lattice needs to
    /// stay visible at 6× against mid-grey without turning a photograph into
    /// mesh.
    private static let pixelGridAlpha: CGFloat = 0.18

    /// Auto draws the pixel lattice at `magnification >= 6`: below six
    /// screen points per pixel the one-point lattice occupies more than a
    /// sixth of each cell and the picture reads as a screen door;
    /// Photoshop's own pixel grid appears at 600 %; and the canvas already
    /// switches to `.none` interpolation at `magnification >= 1`
    /// (`imageInterpolation`), so at 6× the pixel edges are hard already and
    /// the lattice only labels them.
    private static let pixelGridAutoMagnification: CGFloat = 6

    /// On draws at `magnification >= 2` — a FLOOR, not a threshold, so "On
    /// sometimes draws nothing" is deliberate: below 2 the lattice is denser
    /// than the pixels it describes and becomes a grey wash, not a grid.
    private static let pixelGridOnMagnification: CGFloat = 2

    /// The furniture on a smart guide, in SCREEN POINTS: how far an
    /// alignment line overshoots the boxes it relates, and the half-length
    /// of an equal-gap bar's end caps.
    ///
    /// 4 is half `SnapEngine.pullScreenPoints`, the 8-point radius this app
    /// grabs every hairline at. Deriving it from that one number keeps the
    /// annotation visibly smaller than the tolerance that produced it, so a
    /// smart guide's ends never read as a handle you could take hold of.
    private static let smartGuideTickPoints: CGFloat = 4

    // MARK: - When the grids are on screen

    /// True while both lattices stand down: a crop STRAIGHTEN is previewing,
    /// which rotates the picture while an axis-aligned grid would not — the
    /// channel washes' own reason at their own gate, and the only one there
    /// has ever been for hiding the grid.
    ///
    /// It is the straighten ANGLE, not the crop session: `beginCropSession`
    /// sets `cropOverlay` the instant the tool is picked, so gating on the
    /// overlay itself took the grid off the screen for the whole of every
    /// crop — including the ordinary axis-aligned one, which is exactly when
    /// cropping TO the grid is what both features are on for.
    var gridsStandDown: Bool { (cropOverlay?.angle ?? 0) != 0 }

    /// True when the document grid is actually DRAWN. The `.grid` snap
    /// target reads this same property (`DragSnapping.makeSnapEngine`), so
    /// "the grid snaps only while it is drawn" is one predicate two callers
    /// share rather than two conditions that can drift apart — and a crop
    /// box can no longer jump to subdivision lines nobody can see.
    var drawsDocumentGrid: Bool { chrome.showGrid && !gridsStandDown }

    // MARK: - The document grid

    /// The document grid: major lines at the spacing, subdivision lines
    /// between them, all `1 / magnification` hairlines so they keep their
    /// screen weight at any zoom.
    ///
    /// ANCHORED AT CANVAS (0, 0), NOT AT THE RULER ORIGIN. The drawn grid
    /// and the SNAPPED grid must be the same grid, and the snap is analytic
    /// about zero (`SnapEngine.pull`); if one used the origin and the other
    /// used zero they would disagree the moment a user dragged the origin
    /// off the corner — a grid you can see and cannot land on.
    ///
    /// The draw slot is above the base image and its washes, below every
    /// overlay the user is currently manipulating. That is a deliberate
    /// reading of "beneath the content and above the checkerboard": taken
    /// literally — between the checkerboard fill and the image draw — the
    /// grid would be invisible on any opaque document, which is every
    /// photograph, and the feature exists to align content that sits ON the
    /// picture. It also stands down during a crop straighten, for the
    /// identical reason the channel washes already give at their own gate:
    /// the straighten preview rotates the picture while an axis-aligned grid
    /// would not, showing the grid where it will not land.
    ///
    /// Subdivision lines are drawn at `chrome.gridStepX` (the spacing over
    /// the subdivision count), which is the superset of the major lines
    /// Photoshop snaps to — so every line the user can see is a line the
    /// pointer can land on, and the majors are exactly the ones this loop
    /// draws at full weight. The engine takes BOTH ladders and picks the
    /// finest one still separable at the current zoom, so at a zoom where
    /// the subdivisions have closed up into a wash the drawn majors are
    /// still what a drag lands on.
    func drawDocumentGrid(in context: CGContext, dirty: CGRect) {
        // The caller gates both grid calls on `gridsStandDown`; the test is
        // repeated here through the one predicate so the rule travels with
        // the drawing rather than with one call site.
        guard drawsDocumentGrid else { return }
        guard let stepX = chrome.gridStepX, let stepY = chrome.gridStepY else { return }
        // Only the dirty rect is drawn, and only its part of the canvas: the
        // view's bounds ARE the canvas rect, and everything outside is
        // clipped away by the view's forced `clipsToBounds`.
        let area = bounds.intersection(dirty)
        guard area.width > 0, area.height > 0 else { return }

        let cap = CGFloat(Self.maxGridLines)
        let majorX = Self.lineBounds(step: chrome.gridSpacingX, from: area.minX, to: area.maxX)
        let majorY = Self.lineBounds(step: chrome.gridSpacingY, from: area.minY, to: area.maxY)
        let majorCount = Self.lineCount(majorX) + Self.lineCount(majorY)
        // Zero majors is NOT a reason to stop: at a deep zoom the visible
        // strip can sit entirely between two major lines and still be full
        // of subdivisions. The empty paths below draw nothing on their own.
        //
        // A grid whose MAJOR lines alone pass the cap is finer than the
        // screen can separate. Nothing is drawn: a truncated grid would put
        // lines over part of the canvas and none over the rest, which is a
        // lie about where the grid is, and a complete one would be a wash.
        guard majorCount <= cap else { return }

        let divisions = max(1, chrome.gridSubdivisions)
        var subX: (first: CGFloat, last: CGFloat)?
        var subY: (first: CGFloat, last: CGFloat)?
        if divisions > 1 {
            let x = Self.lineBounds(step: stepX, from: area.minX, to: area.maxX)
            let y = Self.lineBounds(step: stepY, from: area.minY, to: area.maxY)
            // Subdivisions are the numerous half of the grid, so they are
            // what the cap drops first: a major-only grid still measures.
            if majorCount + Self.lineCount(x) + Self.lineCount(y) <= cap {
                subX = x
                subY = y
            }
        }

        let ink = DS.gridInk
        context.saveGState()
        // A hairline: one screen point wide whatever the zoom, exactly as
        // every other canvas overlay scales its stroke.
        context.setLineWidth(1 / magnification)

        if subX != nil || subY != nil {
            let path = CGMutablePath()
            if let bounds = subX {
                Self.addLines(
                    to: path, axis: .vertical, indices: bounds, step: stepX,
                    skippingMultiplesOf: divisions, in: area)
            }
            if let bounds = subY {
                Self.addLines(
                    to: path, axis: .horizontal, indices: bounds, step: stepY,
                    skippingMultiplesOf: divisions, in: area)
            }
            if !path.isEmpty {
                context.setStrokeColor(
                    ink.withAlphaComponent(Self.gridSubdivisionAlpha).cgColor)
                context.addPath(path)
                context.strokePath()
            }
        }

        let majors = CGMutablePath()
        if let bounds = majorX {
            Self.addLines(
                to: majors, axis: .vertical, indices: bounds, step: chrome.gridSpacingX,
                skippingMultiplesOf: 0, in: area)
        }
        if let bounds = majorY {
            Self.addLines(
                to: majors, axis: .horizontal, indices: bounds, step: chrome.gridSpacingY,
                skippingMultiplesOf: 0, in: area)
        }
        if !majors.isEmpty {
            context.setStrokeColor(ink.withAlphaComponent(Self.gridMajorAlpha).cgColor)
            context.addPath(majors)
            context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: - The pixel lattice

    /// The one-pixel lattice, drawn only above a zoom threshold: Auto above
    /// `pixelGridAutoMagnification`, On above `pixelGridOnMagnification`,
    /// Off never (the three thresholds carry their reasons at their
    /// declarations).
    ///
    /// It is a lattice on the PIXEL grid, so it is anchored at canvas
    /// (0, 0) like the document grid and for the same reason — a pixel
    /// boundary is not something a ruler origin can move.
    func drawPixelGrid(in context: CGContext, dirty: CGRect) {
        // Same crop-straighten stand-down as the document grid above, and
        // for the same reason: the straighten preview rotates the picture
        // while an axis-aligned lattice would not.
        guard !gridsStandDown else { return }
        let threshold: CGFloat
        switch chrome.pixelGridMode {
        case 0: threshold = Self.pixelGridAutoMagnification
        case 1: threshold = Self.pixelGridOnMagnification
        // 2 is Off, and anything else can only be a corrupted preference,
        // which reads as Off rather than as a surprise lattice.
        default: return
        }
        guard magnification >= threshold else { return }

        let area = bounds.intersection(dirty)
        guard area.width > 0, area.height > 0 else { return }
        let xs = Self.lineBounds(step: 1, from: area.minX, to: area.maxX)
        let ys = Self.lineBounds(step: 1, from: area.minY, to: area.maxY)
        let count = Self.lineCount(xs) + Self.lineCount(ys)
        guard count > 0 else { return }
        // The cap can only bite here on a display large enough to expose
        // 4000 canvas pixels at the 2× floor — 8000 points of window — and
        // at that size the lattice would be a line every two points, the
        // grey wash the floor exists to avoid. Dropping it there is the same
        // decision as the floor, not a different one.
        guard count <= CGFloat(Self.maxGridLines) else { return }

        let path = CGMutablePath()
        if let bounds = xs {
            Self.addLines(
                to: path, axis: .vertical, indices: bounds, step: 1,
                skippingMultiplesOf: 0, in: area)
        }
        if let bounds = ys {
            Self.addLines(
                to: path, axis: .horizontal, indices: bounds, step: 1,
                skippingMultiplesOf: 0, in: area)
        }
        guard !path.isEmpty else { return }
        context.saveGState()
        context.setLineWidth(1 / magnification)
        context.setStrokeColor(DS.gridInk.withAlphaComponent(Self.pixelGridAlpha).cgColor)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Smart Guides

    /// The Smart Guides a live Move or Free Transform drag produced:
    /// alignment lines spanning only the boxes involved, and equal-gap bars
    /// with end caps, in the guide colour's ACCENT so they never read as
    /// guides the user placed.
    ///
    /// The list is what the solver produced from the CORRECTED box, so this
    /// method can never annotate an alignment that did not happen. It is
    /// deliberately NOT gated on `!isTransforming`: a Free Transform drag is
    /// one of the two gestures that produce smart guides. Nor is it gated on
    /// `chrome.guidesVisible`: Show Guides governs the guides a user placed,
    /// and a smart guide is feedback about the drag in flight — hiding it
    /// with them would leave the pointer snapping to lines with nothing on
    /// screen to say why.
    ///
    /// Everything is one path at one weight — a `1 / magnification` hairline
    /// — because the alignment lines and the gap bars are one statement
    /// about one drag, and a heavier bar would read as a selected object
    /// rather than as an annotation.
    func drawSmartGuides() {
        guard !smartGuides.isEmpty else { return }
        let scale = magnification
        let tick = Self.smartGuideTickPoints / scale
        let path = NSBezierPath()
        path.lineWidth = 1 / scale
        for line in smartGuides {
            switch line {
            case .alignment(let axis, let position, let span):
                guard position.isFinite, span.lowerBound.isFinite, span.upperBound.isFinite
                else { continue }
                // The overshoot at each end is what makes the line read as
                // an annotation ACROSS the two boxes rather than as an edge
                // of one of them. The solver already clipped the span to the
                // canvas, so at an edge the overshoot is clipped away with
                // everything else this view draws outside its bounds — the
                // line simply stops at the edge, which is correct.
                Self.add(
                    to: path, axis: axis, at: position,
                    from: span.lowerBound - tick, to: span.upperBound + tick)
            case .spacing(let axis, let gap, let at):
                guard at.isFinite, gap.lowerBound.isFinite, gap.upperBound.isFinite
                else { continue }
                // The bar runs ALONG the axis's measuring direction (x for a
                // `.vertical` axis) at `at` on the other one, with a cap at
                // each end so a gap reads as a measured quantity with two
                // ends and not as an alignment line that ran short.
                Self.add(to: path, axis: Self.other(axis), at: at,
                         from: gap.lowerBound, to: gap.upperBound)
                for end in [gap.lowerBound, gap.upperBound] {
                    Self.add(to: path, axis: axis, at: end, from: at - tick, to: at + tick)
                }
            }
        }
        guard !path.isEmpty else { return }
        chrome.guideColor.smartColor.setStroke()
        path.stroke()
    }

    // MARK: - Shared line math

    /// The other axis. A `.vertical` line is a constant-X line, so its
    /// perpendicular is the constant-Y one — used by the gap bars, which run
    /// along their axis's measuring direction and are capped across it. A
    /// local helper rather than a member on `SnapAxis`: the engine's own
    /// files have no use for it, and one drawing detail should not widen a
    /// shared type.
    private static func other(_ axis: SnapAxis) -> SnapAxis {
        axis == .vertical ? .horizontal : .vertical
    }

    /// One segment of the line at `position` on `axis`, running from `from`
    /// to `to` on the other axis. A `.vertical` axis is a constant-X line,
    /// so it runs along Y — the same convention the snapping engine uses.
    private static func add(
        to path: NSBezierPath, axis: SnapAxis, at position: CGFloat,
        from: CGFloat, to: CGFloat
    ) {
        switch axis {
        case .vertical:
            path.move(to: CGPoint(x: position, y: from))
            path.line(to: CGPoint(x: position, y: to))
        case .horizontal:
            path.move(to: CGPoint(x: from, y: position))
            path.line(to: CGPoint(x: to, y: position))
        }
    }

    /// Adds one line per index in `indices` at `CGFloat(index) * step`,
    /// spanning the dirty area on the other axis; indices that are whole
    /// multiples of `skippingMultiplesOf` are left out, which is how the
    /// subdivision pass avoids re-drawing the major lines underneath its own
    /// lighter ink. Pass 0 to skip nothing.
    ///
    /// The index IS the anchor: every line sits at a whole multiple of the
    /// step measured from canvas zero, which is exactly the coordinate
    /// `SnapEngine`'s analytic grid candidate produces, so the drawn grid
    /// and the snapped grid are the same grid by construction.
    private static func addLines(
        to path: CGMutablePath, axis: SnapAxis, indices: (first: CGFloat, last: CGFloat),
        step: CGFloat, skippingMultiplesOf skip: Int, in area: CGRect
    ) {
        guard step.isFinite, step > 0 else { return }
        for index in Int(indices.first)...Int(indices.last) {
            if skip > 0, index % skip == 0 { continue }
            let position = CGFloat(index) * step
            switch axis {
            case .vertical:
                path.move(to: CGPoint(x: position, y: area.minY))
                path.addLine(to: CGPoint(x: position, y: area.maxY))
            case .horizontal:
                path.move(to: CGPoint(x: area.minX, y: position))
                path.addLine(to: CGPoint(x: area.maxX, y: position))
            }
        }
    }

    /// The first and last INDEX of a line at `step` from canvas zero that
    /// falls inside `lo…hi`, or nil when the interval holds none.
    ///
    /// The bounds stay FLOATING POINT and are never converted to `Int` here,
    /// on purpose: a degenerate step (a 0.001 px grid on a 30000 px canvas)
    /// can name more indices than `Int` can hold, and converting them in
    /// order to count them would trap. The caller counts in `CGFloat`,
    /// refuses what it cannot draw, and only then converts a range it has
    /// already bounded.
    private static func lineBounds(
        step: CGFloat, from lo: CGFloat, to hi: CGFloat
    ) -> (first: CGFloat, last: CGFloat)? {
        guard step.isFinite, step > 0, lo.isFinite, hi.isFinite, hi >= lo else { return nil }
        let first = (lo / step).rounded(.up)
        let last = (hi / step).rounded(.down)
        // 1e15 is far above any index a 30000 px canvas can produce and far
        // below Int.max, so a range that clears it converts safely.
        guard first.isFinite, last.isFinite, last >= first,
            abs(first) < 1e15, abs(last) < 1e15
        else { return nil }
        return (first, last)
    }

    /// How many lines a `lineBounds` result names — left in floating point,
    /// for the reason `lineBounds` gives.
    private static func lineCount(_ bounds: (first: CGFloat, last: CGFloat)?) -> CGFloat {
        guard let bounds = bounds else { return 0 }
        return bounds.last - bounds.first + 1
    }
}
