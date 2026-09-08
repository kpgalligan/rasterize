import AppKit

// The ONE snapping engine. Every drag in the app that can snap asks this
// type and nothing else: the Move drag, all four Free Transform drags, the
// crop box, the shape drag and the shape re-edit, the three marquees, the
// lasso vertex and the guide drag itself. `DragSnapping.swift` carries the
// completeness table — which drag calls what, and which drags deliberately
// do not snap at all.
//
// PURE GEOMETRY. No document access, no view, no `self` mutation: `pull` is
// a function of its arguments, which is what makes the phase's behaviour
// checkable without the screen. There is no Swift test target in this
// project, so "unit-testable" means exactly that — the same call can be
// driven from a scratch harness, and was.
//
// ── The rules, stated once, here ───────────────────────────────────────
//
// PRIORITY. Within the pull radius the NEAREST line wins. On a tie
// (|d₁ − d₂| ≤ 0.01 canvas px) the order is
//
//     guides > layer edges/centres > selection bounds > document bounds > grid
//
// because a guide is the most deliberate thing on the canvas — a user put it
// there by hand — while the grid is the most numerous and would otherwise
// swamp everything it coincides with. Exactly ONE line per axis is applied,
// and a call is told THE CORRECTION AND NOTHING ELSE: no "here is what you
// landed on" list comes back, because nothing in the app draws one. The only
// lines this phase paints while a drag is in flight are the smart guides, and
// `SmartGuideSolver.drawings` derives those from the CORRECTED box rather
// than from the winning candidate — which is what keeps a drawn line from
// claiming an alignment the drag did not actually get. (An earlier draft did
// return every line at the winning coordinate, for a drawing pass that was
// never written: a second full candidate scan and an array allocation on both
// axes of every tick, read by nobody. It is gone rather than left to describe
// behaviour the app does not have.) Smart-guide equal-spacing candidates
// enter the same contest through `extra:` and rank with `.layer`, so there is
// exactly one offset per axis in the whole phase.
//
// PULL RADIUS: 8 SCREEN POINTS, converted to canvas pixels as
// `8 / magnification` at the moment of use. The app already uses 8 screen
// points as its "grab a hairline" radius everywhere
// (`ImageCanvasView.transformHandleSize`, the lasso-close test), so a snap
// that pulls at the same distance a handle grabs at is one number, not two.
// Being in SCREEN points is what makes it zoom-independent: at 800 % the
// pull is 1 canvas pixel — exactly what you want when placing a pixel — and
// at 25 % it is 32 canvas pixels, which is what you want when composing a
// page.
//
// A PERIODIC TARGET CAPS ITS OWN PULL AT A QUARTER OF ITS PERIOD, and a grid
// LADDER whose lines are closer together on screen than TWICE the pull is
// dropped — but the grid has TWO ladders, and only the fine one is dropped
// first. Both numbers are load-bearing and neither is a round-up of the
// other:
//
//   • A QUARTER, not a half, because the grid candidate is the NEAREST
//     multiple, computed analytically — its distance is at most half a
//     period by construction, so a cap at half a period excludes nothing and
//     EVERY coordinate on the canvas snaps. A quarter leaves half of every
//     cell out of reach, which is the largest cap that still lets someone
//     put an edge between two grid lines.
//   • TWICE the pull, not the pull, because the radius is
//     `pullScreenPoints / magnification`: a ladder admitted at exactly the
//     pull has a radius equal to its own whole period, which is the cap's
//     worst case rather than its best. At twice the pull the radius is at
//     most half the period and the cap clamps a real number.
//
// Without both, at 12 % zoom the pull is 67 canvas px while the default grid
// subdivision is 25 px: every coordinate would be inside some grid line's
// radius, nothing could be placed off the grid, and the winning line would
// flip on every pointer sample. Lines closer together on screen than the
// pull is wide are not separable by eye either, so snapping to them is
// noise. The MAJOR lines are a separate ladder and are only dropped on their
// own terms: at 25 % the default subdivisions are 6.25 screen points apart
// and go, while the majors are 25 apart, drawn, and snappable
// (`gridStep(_:magnification:)`). This applies to the GRID ONLY — layer
// edges have no period, and a busy document's nearest edge is still a real
// object the user aimed at.
//
// THE GRID IS ANCHORED AT CANVAS (0, 0), NOT AT THE RULER ORIGIN, and it is
// ANALYTIC — `(coord / step).rounded() * step` — never a materialized list
// (a 10 px grid on a 10 000 px canvas is 1000 lines rebuilt for nothing).
// The DRAWN grid is anchored at canvas zero for the same reason
// (`ImageCanvasView+Grid.swift`): if one used the origin and the other used
// zero they would disagree the moment a user dragged the origin off the
// corner — a grid you can see and cannot land on. The ruler origin moves
// LABELS and the New Guide sheet's typed number, and nothing else.
//
// SUSPEND: ⌃ (control), Photoshop's own and the only free modifier on the
// canvas (⇧/⌥/⇧⌥ are consumed at mouse-down by the marquees' combine modes,
// ⇧ and ⌥ again by the transform box, ⌘ by distort). It is read on every
// drag TICK, never latched at mouse-down, so a user can suspend mid-drag.

// MARK: - Vocabulary

/// Which way a candidate line runs. `vertical` is a line of constant X —
/// the same convention `GuideOrientation.vertical` uses.
enum SnapAxis {
    case vertical
    case horizontal
}

/// What produced a line, which is also its tie-break rank (see the header).
enum SnapKind {
    case guide
    case layer
    case selection
    case documentBounds
    case grid

    /// Lower wins a tie.
    var rank: Int {
        switch self {
        case .guide: return 0
        case .layer: return 1
        case .selection: return 2
        case .documentBounds: return 3
        case .grid: return 4
        }
    }
}

/// Whether a candidate line is rounded to a whole pixel BEFORE the distance
/// test.
///
/// Snapping does NOT round by default: a guide at x = 100.5 pulls an edge to
/// exactly 100.5. `.wholePixels` rounds each candidate first, so the snapped
/// result is on a whole pixel AND on the (rounded) line simultaneously —
/// never on one and then nudged off the other, which is what snapping
/// exactly and rounding afterwards would do.
///
/// Four sites opt in, each for its own reason: the crop box (its commit
/// rounds each edge, so a half-pixel snap would commit a pixel away from
/// what was seen), the rect marquee (already `.integral` live and at commit,
/// and `.integral` rounds OUTWARD), the Move drag (the canvas hands it an
/// integer delta) and a guide drag (its committed position is `.rounded()`).
enum SnapQuantize {
    case exact
    case wholePixels
}

/// Which classes of line a call may snap to — the View ▸ Snap To submenu,
/// stored as an `Int` raw value in `ViewToolOptions`. Modelled on
/// `LockFlags`.
struct SnapTarget: OptionSet, Equatable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue & SnapTarget.allBits }

    static let guides = SnapTarget(rawValue: 1 << 0)
    static let grid = SnapTarget(rawValue: 1 << 1)
    static let layers = SnapTarget(rawValue: 1 << 2)
    static let documentBounds = SnapTarget(rawValue: 1 << 3)
    static let selection = SnapTarget(rawValue: 1 << 4)

    static let all: SnapTarget = [.guides, .grid, .layers, .documentBounds, .selection]
    private static let allBits = 0b1_1111

    /// The menu's vocabulary in submenu order, tag-indexed by
    /// `toggleSnapTarget(_:)`. One table, so the menu, the validation and
    /// the store can never disagree about a name.
    static let named: [(name: String, target: SnapTarget)] = [
        ("Guides", .guides), ("Grid", .grid), ("Layers", .layers),
        ("Document Bounds", .documentBounds), ("Selection", .selection),
    ]
}

/// Which of a rect's coordinates a call may move.
///
/// THREE INDEX SPACES MEET HERE AND THEY DO NOT AGREE — hence three
/// constructors and deliberately no generic `forHandle(Int)`:
///  • `CropSession.handles(of:)` is TL, TR, BR, BL, T, R, B, L
///    (`CropTool.swift`) — the crop box AND `ShapeEditSession.Drag.handle`.
///  • `TransformHandle.allCases` is TL, top, TR, right, BR, bottom, BL, left
///    (`LayerTransform.swift`) — index 1 is `.top` here and TR there.
///  • `.distort(corner:)` is a QUAD index, TL 0, TR 1, BR 2, BL 3.
/// Bridging any two with `firstIndex(of:)` moves the wrong edges, silently,
/// and only for one of the drags.
struct SnapEdges: OptionSet, Equatable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let left = SnapEdges(rawValue: 1 << 0)
    static let right = SnapEdges(rawValue: 1 << 1)
    static let centerX = SnapEdges(rawValue: 1 << 2)
    static let top = SnapEdges(rawValue: 1 << 3)
    static let bottom = SnapEdges(rawValue: 1 << 4)
    static let centerY = SnapEdges(rawValue: 1 << 5)

    static let all: SnapEdges = [.left, .right, .centerX, .top, .bottom, .centerY]
    static let horizontalAll: SnapEdges = [.left, .right, .centerX]
    static let verticalAll: SnapEdges = [.top, .bottom, .centerY]

    /// `CropSession.handles(of:)` order: TL, TR, BR, BL, T, R, B, L. Used by
    /// the crop box and by `ShapeEditSession.Drag.handle`, which indexes the
    /// same table. An out-of-range index moves nothing, which is the safe
    /// answer: a handle we cannot name is a handle we must not snap.
    static func forCropHandle(_ index: Int) -> SnapEdges {
        switch index {
        case 0: return [.left, .top]
        case 1: return [.right, .top]
        case 2: return [.right, .bottom]
        case 3: return [.left, .bottom]
        case 4: return [.top]
        case 5: return [.right]
        case 6: return [.bottom]
        case 7: return [.left]
        default: return []
        }
    }

    /// Derived from the handle's own `unit` (−1 / 0 / +1 per axis) rather
    /// than from a second table, so the two can never fall out of step.
    ///
    /// A handle whose `unit` is 0 on an axis contributes that axis's CENTRE
    /// line, which is only meaningful when the caller has already decided
    /// the handle may drive that axis. An EDGE handle cannot: `scaling`
    /// solves in the box's own axes and its span there is zero. So the
    /// caller offers X candidates only when `handle.unit.x != 0` and Y only
    /// when `handle.unit.y != 0` — the rule stated in `DragSnapping.swift`'s
    /// header, enforced there rather than here so this stays one expression.
    static func forTransformHandle(_ handle: TransformHandle) -> SnapEdges {
        var edges: SnapEdges = []
        let unit = handle.unit
        if unit.x < 0 {
            edges.insert(.left)
        } else if unit.x > 0 {
            edges.insert(.right)
        } else {
            edges.insert(.centerX)
        }
        if unit.y < 0 {
            edges.insert(.top)
        } else if unit.y > 0 {
            edges.insert(.bottom)
        } else {
            edges.insert(.centerY)
        }
        return edges
    }

    /// Quad-corner order: TL 0, TR 1, BR 2, BL 3 — what
    /// `TransformDrag.distort(corner:)` carries.
    static func forQuadCorner(_ corner: Int) -> SnapEdges {
        switch corner {
        case 0: return [.left, .top]
        case 1: return [.right, .top]
        case 2: return [.right, .bottom]
        case 3: return [.left, .bottom]
        default: return []
        }
    }
}

/// One candidate line in canvas space.
///
/// It carries NO span — the extent of the box that produced it. Nothing draws
/// a candidate line: the smart guides compute their own spans from the
/// corrected box (`SmartGuideSolver.alignments`), and building a
/// `ClosedRange` per line per box for a field only the deleted hit list ever
/// read was two allocations per box on every engine build, and on the crop,
/// transform and shape-re-edit paths that is per mouse event.
///
/// `appliesTo` names WHICH coordinate of the moving geometry the line was
/// computed for, and nil — the ordinary case — means "any of them". A guide,
/// a layer edge or a document edge is a place in the picture and any edge of
/// the moving box may land on it. An equal-spacing candidate is not: it is
/// the position ONE named edge must reach for two gaps to become equal
/// (`SmartGuideSolver.candidates`), and applying it to a different edge
/// equalizes nothing.
struct SnapLine {
    let axis: SnapAxis
    let position: CGFloat
    let kind: SnapKind
    let appliesTo: SnapEdges?

    init(
        axis: SnapAxis, position: CGFloat, kind: SnapKind, appliesTo: SnapEdges? = nil
    ) {
        self.axis = axis
        self.position = position
        self.kind = kind
        self.appliesTo = appliesTo
    }
}

/// One coordinate of the moving geometry, tagged with which coordinate it is.
///
/// The tag exists for one reason: a candidate line that names an edge may
/// only pull THAT edge. `pull` is handed a box's whole triple at once and
/// tries every coordinate against every candidate, so without the tag an
/// equal-spacing position computed for `minX` could win on `maxX` — the box
/// would take a correction of up to its own width towards a coordinate that
/// equalizes nothing and aligns to nothing, and the drawings (computed from
/// the corrected box) would then show nothing at all to explain the pull.
struct SnapCoordinate {
    let value: CGFloat
    /// `.left`/`.centerX`/`.right` on the vertical axis, `.top`/`.centerY`/
    /// `.bottom` on the horizontal — or EMPTY for a bare point that is no
    /// named edge of anything, which no edge-specific candidate may pull.
    let edge: SnapEdges

    init(value: CGFloat, edge: SnapEdges = []) {
        self.value = value
        self.edge = edge
    }
}

/// What the pointer state contributes, per call. Magnification changes far
/// more often than the target list does, so it is never a stored field of
/// the engine — it arrives on every call instead.
struct SnapContext {
    let magnification: CGFloat
    /// ⌃ held on THIS tick.
    let suspended: Bool

    init(magnification: CGFloat, suspended: Bool) {
        self.magnification = magnification
        self.suspended = suspended
    }

    /// 100 %, nothing suspended — the value a stub or a non-view caller uses.
    static let identity = SnapContext(magnification: 1, suspended: false)
}

// MARK: - The engine

/// The candidate lines one gesture may snap to, built ONCE at that
/// gesture's mouse-down and held unchanged for the whole drag
/// (`DragSnapping.makeSnapEngine(for:)` — the reason is a measurement: the
/// content-bounds fold behind `layerRects` is a per-pixel sweep, and a Move
/// drag posts a document change on every mouse-moved event).
struct SnapEngine {
    /// Guides, layer edges and centres, the selection's bounds and the
    /// document's — everything that is a fixed list. The grid is NOT here:
    /// it is analytic (see `gridStepX`).
    var lines: [SnapLine] = []
    /// The static layer boxes Smart Guides measure spacing between; the
    /// gesture's own subject is already excluded.
    var layerRects: [CGRect] = []
    /// Canvas pixels between grid SUBDIVISION lines, nil when the grid is
    /// off or is not a snap target.
    var gridStepX: CGFloat?
    var gridStepY: CGFloat?
    /// Canvas pixels between grid MAJOR lines — the heavy ones
    /// `drawDocumentGrid` paints — nil on the same terms.
    ///
    /// Both ladders are carried because the two stop being separable on
    /// screen at different zooms, and the coarse one is still perfectly
    /// snappable when the fine one is noise: at 25 % with the default
    /// 100 px / 4 grid the subdivisions are 6.25 screen points apart (under
    /// the 16 the bar asks for, and not a ladder anyone can aim at) while the
    /// majors are 25 apart and plainly drawn. Carrying only the subdivisions
    /// made `gridStep` drop the whole target there, so Snap To ▸ Grid did
    /// nothing at all below 64 % zoom — with its menu item still check-marked
    /// and the grid still on screen.
    var gridMajorX: CGFloat?
    var gridMajorY: CGFloat?
    var canvasSize: CGSize = .zero
    /// The View ▸ Snap master switch, and the per-tool overrides folded in.
    var isEnabled = false

    init(
        lines: [SnapLine] = [], layerRects: [CGRect] = [], gridStepX: CGFloat? = nil,
        gridStepY: CGFloat? = nil, gridMajorX: CGFloat? = nil, gridMajorY: CGFloat? = nil,
        canvasSize: CGSize = .zero, isEnabled: Bool = false
    ) {
        self.lines = lines
        self.layerRects = layerRects
        self.gridStepX = gridStepX
        self.gridStepY = gridStepY
        self.gridMajorX = gridMajorX
        self.gridMajorY = gridMajorY
        self.canvasSize = canvasSize
        self.isEnabled = isEnabled
    }

    /// Snaps nothing. The value every stub, every suspended gesture and
    /// every canvas with no document holds.
    static let inactive = SnapEngine()

    /// See the file header: 8 screen points, the app's existing "grab a
    /// hairline" radius, in SCREEN space so the pull is zoom-independent.
    static let pullScreenPoints: CGFloat = 8

    /// Two coordinates closer than this are the same coordinate: the tie
    /// threshold here, and the "these now match exactly" test the smart
    /// guides draw from. A hundredth of a canvas pixel is far below anything
    /// a 32× zoom can show.
    static let epsilon: CGFloat = 0.01

    // MARK: The core

    /// THE CORE. The correction to add to every coordinate in `coordinates`
    /// so that the best of them lands on a line — the whole answer, since
    /// nothing draws the line that was landed on (see the header).
    ///
    /// `extra` carries per-tick candidates the engine could not know at
    /// mouse-down — today exactly the smart guides' equal-spacing positions,
    /// which depend on where the moving box currently is.
    ///
    /// Every coordinate is tried against every candidate, EXCEPT that a
    /// candidate naming edges (`SnapLine.appliesTo`) is tried only against a
    /// coordinate that is one of them. That is what keeps an equal-spacing
    /// position computed for one edge of the box from winning on another.
    ///
    /// nil when nothing is within the pull, when `!isEnabled`, when
    /// `ctx.suspended`, or when there is nothing to snap.
    func pull(
        _ coordinates: [SnapCoordinate], axis: SnapAxis, in ctx: SnapContext,
        quantize: SnapQuantize, extra: [SnapLine] = []
    ) -> CGFloat? {
        guard isEnabled, !ctx.suspended, !coordinates.isEmpty else { return nil }
        let magnification = max(ctx.magnification, 0.001)
        let radius = Self.pullScreenPoints / magnification
        guard radius.isFinite, radius > 0 else { return nil }
        let live = coordinates.filter { $0.value.isFinite }
        guard !live.isEmpty else { return nil }

        let candidates = (lines + extra)
            .filter { $0.axis == axis && $0.position.isFinite }
            .map { (line: $0, position: Self.quantized($0.position, quantize)) }
        // Resolved ONCE for the call: it depends on the axis and the
        // magnification alone, and both loops below ask the same question.
        let grid = gridStep(axis, magnification: magnification)

        var bestOffset: CGFloat?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var bestRank = Int.max

        for coordinate in live {
            for candidate in candidates where Self.applies(candidate.line, to: coordinate) {
                let offset = candidate.position - coordinate.value
                let distance = abs(offset)
                guard distance <= radius else { continue }
                if Self.beats(
                    distance: distance, rank: candidate.line.kind.rank,
                    bestDistance: bestDistance, bestRank: bestRank)
                {
                    bestOffset = offset
                    bestDistance = distance
                    bestRank = candidate.line.kind.rank
                }
            }
            // The grid is analytic, about canvas ZERO, and caps its own pull
            // at a QUARTER of its period so a low zoom cannot quantize the
            // canvas (`gridPull`).
            if let step = grid {
                let position = Self.quantized(
                    (coordinate.value / step).rounded() * step, quantize)
                let offset = position - coordinate.value
                let distance = abs(offset)
                if distance <= Self.gridPull(radius, step),
                   Self.beats(
                       distance: distance, rank: SnapKind.grid.rank,
                       bestDistance: bestDistance, bestRank: bestRank)
                {
                    bestOffset = offset
                    bestDistance = distance
                    bestRank = SnapKind.grid.rank
                }
            }
        }

        return bestOffset
    }

    /// The UNTAGGED form: coordinates that are no named edge of any box — a
    /// bare point, a guide's one coordinate, a handle's one axis. An
    /// edge-specific candidate can never pull one of these, which is the
    /// right answer: there is no box here whose gaps a spacing candidate
    /// could equalize.
    func pull(
        _ coordinates: [CGFloat], axis: SnapAxis, in ctx: SnapContext,
        quantize: SnapQuantize, extra: [SnapLine] = []
    ) -> CGFloat? {
        pull(
            coordinates.map { SnapCoordinate(value: $0) }, axis: axis, in: ctx,
            quantize: quantize, extra: extra)
    }

    /// Whether `line` may pull `coordinate`. A line that names no edge pulls
    /// any of them; one that names edges pulls only a coordinate that IS one
    /// of them.
    private static func applies(_ line: SnapLine, to coordinate: SnapCoordinate) -> Bool {
        guard let appliesTo = line.appliesTo else { return true }
        return !appliesTo.isDisjoint(with: coordinate.edge)
    }

    /// Nearest wins; a tie inside `epsilon` goes to the more deliberate
    /// kind (see the header's priority order).
    private static func beats(
        distance: CGFloat, rank: Int, bestDistance: CGFloat, bestRank: Int
    ) -> Bool {
        if distance < bestDistance - epsilon { return true }
        if distance > bestDistance + epsilon { return false }
        return rank < bestRank
    }

    private static func quantized(_ position: CGFloat, _ quantize: SnapQuantize) -> CGFloat {
        quantize == .wholePixels ? position.rounded() : position
    }

    /// The FINEST grid ladder on `axis` a person could aim at — the
    /// subdivisions while they are separable on screen, else the major
    /// lines, else nothing at all.
    ///
    /// Per axis, and per zoom, because "separable" is a screen-space
    /// question: a ladder whose lines sit closer together than the pull
    /// itself cannot be picked out by eye and snapping to it is noise (the
    /// header's periodic rule). Dropping the whole target the moment the
    /// SUBDIVISIONS failed that test was the first form of this rule and it
    /// took the majors down with them, which is a grid drawn 25 screen
    /// points apart that no drag would go anywhere near.
    private func gridStep(_ axis: SnapAxis, magnification: CGFloat) -> CGFloat? {
        let subdivision = axis == .vertical ? gridStepX : gridStepY
        let major = axis == .vertical ? gridMajorX : gridMajorY
        return Self.separable(subdivision, magnification)
            ?? Self.separable(major, magnification)
    }

    /// `step` when it is a usable ladder at `magnification`, nil otherwise.
    ///
    /// The bar is TWICE the pull, not the pull. At exactly the pull the two
    /// rules that keep a periodic target honest cancel each other out: the
    /// radius is `pullScreenPoints / magnification`, so a ladder admitted at
    /// `step * magnification == pullScreenPoints` has a radius equal to its
    /// whole period and a grid line within reach of every coordinate on the
    /// canvas. At twice the pull the radius is at most HALF the period, which
    /// is where `gridPull`'s quarter-period cap starts doing real work rather
    /// than clamping a number that was already smaller. With the default
    /// 100 px / 4 grid that puts the subdivisions (25 px) on offer at 64 %
    /// zoom and up, the majors (100 px) from 16 % up, and no grid target at
    /// all below that — where the whole grid is drawn closer together than a
    /// pointer could aim.
    private static func separable(_ step: CGFloat?, _ magnification: CGFloat) -> CGFloat? {
        guard let step = step, step.isFinite, step > 0,
              step * magnification >= 2 * pullScreenPoints
        else { return nil }
        return step
    }

    /// The grid's pull: a QUARTER of its period, never more.
    ///
    /// This is the rule that stops a ladder quantizing the canvas, and it
    /// has to be a quarter rather than a half because the grid candidate is
    /// computed ANALYTICALLY as the nearest multiple — its distance is at
    /// most half a period by construction, so a cap at half a period
    /// excludes nothing and every coordinate snaps. A quarter leaves exactly
    /// half of every cell out of reach, which is the largest cap that still
    /// lets a user put an edge BETWEEN two grid lines: the one thing the
    /// symptom this cap exists for takes away.
    private static func gridPull(_ radius: CGFloat, _ step: CGFloat) -> CGFloat {
        min(radius, step / 4)
    }

    // MARK: The three shapes a caller asks in

    /// One point, both axes independently.
    func snapped(
        point: CGPoint, in ctx: SnapContext, quantize: SnapQuantize = .exact
    ) -> CGPoint {
        let x = pull([point.x], axis: .vertical, in: ctx, quantize: quantize)
        let y = pull([point.y], axis: .horizontal, in: ctx, quantize: quantize)
        return CGPoint(x: point.x + (x ?? 0), y: point.y + (y ?? 0))
    }

    /// A rect, with `edges` naming which of its coordinates may move.
    ///
    /// A move drag passes `.all` and the whole rect TRANSLATES; a handle
    /// drag passes the handle's own edges and only those move, which is what
    /// makes a corner drag resize instead of slide.
    func snapped(
        rect: CGRect, edges: SnapEdges, in ctx: SnapContext, quantize: SnapQuantize = .exact
    ) -> CGRect {
        var coordinatesX: [SnapCoordinate] = []
        if edges.contains(.left) { coordinatesX.append(.init(value: rect.minX, edge: .left)) }
        if edges.contains(.centerX) {
            coordinatesX.append(.init(value: rect.midX, edge: .centerX))
        }
        if edges.contains(.right) { coordinatesX.append(.init(value: rect.maxX, edge: .right)) }
        var coordinatesY: [SnapCoordinate] = []
        if edges.contains(.top) { coordinatesY.append(.init(value: rect.minY, edge: .top)) }
        if edges.contains(.centerY) {
            coordinatesY.append(.init(value: rect.midY, edge: .centerY))
        }
        if edges.contains(.bottom) {
            coordinatesY.append(.init(value: rect.maxY, edge: .bottom))
        }

        let x = coordinatesX.isEmpty
            ? nil : pull(coordinatesX, axis: .vertical, in: ctx, quantize: quantize)
        let y = coordinatesY.isEmpty
            ? nil : pull(coordinatesY, axis: .horizontal, in: ctx, quantize: quantize)

        var minX = rect.minX
        var maxX = rect.maxX
        if let offset = x {
            if edges.contains(.left), edges.contains(.right) {
                minX += offset
                maxX += offset
            } else if edges.contains(.left) {
                minX = min(minX + offset, maxX)
            } else if edges.contains(.right) {
                maxX = max(maxX + offset, minX)
            } else {
                minX += offset
                maxX += offset
            }
        }
        var minY = rect.minY
        var maxY = rect.maxY
        if let offset = y {
            if edges.contains(.top), edges.contains(.bottom) {
                minY += offset
                maxY += offset
            } else if edges.contains(.top) {
                minY = min(minY + offset, maxY)
            } else if edges.contains(.bottom) {
                maxY = max(maxY + offset, minY)
            } else {
                minY += offset
                maxY += offset
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The DELTA form the Move tool and every `.move` sub-drag need.
    ///
    /// `rect` is the PRESS-TIME box and `delta` the total offset so far;
    /// the result is the corrected TOTAL. Snapping a delta directly would
    /// snap the grab offset, not the box's edges — which is the bug this
    /// overload exists to prevent.
    func snappedDelta(
        of rect: CGRect, by delta: CGVector, in ctx: SnapContext,
        quantize: SnapQuantize = .exact, extra: [SnapLine] = []
    ) -> CGVector {
        let moved = rect.offsetBy(dx: delta.dx, dy: delta.dy)
        let x = pull(
            Self.coordinates(of: moved, axis: .vertical), axis: .vertical, in: ctx,
            quantize: quantize, extra: extra)
        let y = pull(
            Self.coordinates(of: moved, axis: .horizontal), axis: .horizontal, in: ctx,
            quantize: quantize, extra: extra)
        return CGVector(dx: delta.dx + (x ?? 0), dy: delta.dy + (y ?? 0))
    }

    // MARK: Building blocks the callers share

    /// A translating box's three coordinates on `axis`, each TAGGED with
    /// which coordinate it is. The one spelling every caller that offers
    /// equal-spacing candidates uses, because an untagged triple is exactly
    /// what lets a candidate meant for one edge win on another.
    static func coordinates(of rect: CGRect, axis: SnapAxis) -> [SnapCoordinate] {
        axis == .vertical
            ? [
                SnapCoordinate(value: rect.minX, edge: .left),
                SnapCoordinate(value: rect.midX, edge: .centerX),
                SnapCoordinate(value: rect.maxX, edge: .right),
            ]
            : [
                SnapCoordinate(value: rect.minY, edge: .top),
                SnapCoordinate(value: rect.midY, edge: .centerY),
                SnapCoordinate(value: rect.maxY, edge: .bottom),
            ]
    }

    /// The four canvas edges plus its two centre lines, as `.documentBounds`
    /// candidates.
    static func documentLines(canvas: CGSize) -> [SnapLine] {
        guard canvas.width > 0, canvas.height > 0 else { return [] }
        return [
            SnapLine(axis: .vertical, position: 0, kind: .documentBounds),
            SnapLine(axis: .vertical, position: canvas.width / 2, kind: .documentBounds),
            SnapLine(axis: .vertical, position: canvas.width, kind: .documentBounds),
            SnapLine(axis: .horizontal, position: 0, kind: .documentBounds),
            SnapLine(axis: .horizontal, position: canvas.height / 2, kind: .documentBounds),
            SnapLine(axis: .horizontal, position: canvas.height, kind: .documentBounds),
        ]
    }

    /// A box's six lines — both edges and the centre on each axis.
    ///
    /// A line is a bare coordinate: what a smart guide is DRAWN across comes
    /// from the corrected box and its partner, in `SmartGuideSolver`, so a
    /// candidate needs no extent of its own (see `SnapLine`).
    static func lines(of rect: CGRect, kind: SnapKind) -> [SnapLine] {
        guard rect.width.isFinite, rect.height.isFinite else { return [] }
        return [
            SnapLine(axis: .vertical, position: rect.minX, kind: kind),
            SnapLine(axis: .vertical, position: rect.midX, kind: kind),
            SnapLine(axis: .vertical, position: rect.maxX, kind: kind),
            SnapLine(axis: .horizontal, position: rect.minY, kind: kind),
            SnapLine(axis: .horizontal, position: rect.midY, kind: kind),
            SnapLine(axis: .horizontal, position: rect.maxY, kind: kind),
        ]
    }
}

// MARK: - Smart Guides

/// What a smart guide draws: an alignment line between boxes that now match
/// exactly, or a bar marking one of a pair of equal gaps.
enum SmartGuideLine {
    /// A line at `position` on `axis`, spanning `span` on the other axis.
    case alignment(axis: SnapAxis, position: CGFloat, span: ClosedRange<CGFloat>)
    /// A gap bar: `gap` is the extent ALONG `axis`'s measuring direction
    /// (x for `.vertical`, y for `.horizontal`) and `at` the coordinate on
    /// the other axis the bar is drawn at.
    case spacing(axis: SnapAxis, gap: ClosedRange<CGFloat>, at: CGFloat)
}

/// Equal-spacing candidates and ALL the smart-guide drawings.
///
/// IT NEVER RETURNS A CORRECTION, and that is the phase's most important
/// structural rule. Comparing the moving box's `minX/midX/maxX` against
/// every static box's `minX/midX/maxX` is EXACTLY what `SnapEngine.pull`
/// already does against the `.layers` target, whose lines are those same
/// edges and centres — so alignment produces no second offset here. Two
/// functions deriving the same correction from the same rects is how a
/// layer gets corrected twice, or corrected by one and annotated by the
/// other. Equal spacing is the solver's only candidate contribution, and it
/// enters `pull` through `extra:` to compete under the ordinary priority
/// rules; the drawings are then computed from the CORRECTED box, so they can
/// never annotate an alignment that did not happen.
enum SmartGuideSolver {
    /// The most static boxes a spacing search will consider, ordered by
    /// distance from the moving box's centre. The search is O(n²) in pairs,
    /// and it runs on every drag tick; 64 boxes is far more than any
    /// composition a user is aligning by eye, and it keeps a 1024-entry
    /// document's tick cost flat.
    static let maxStatics = 64

    /// Two coordinates this close are equal (the engine's own epsilon).
    private static let epsilon = SnapEngine.epsilon

    /// The `statics` a solve should run over: the nearest `maxStatics`
    /// boxes to `moving`'s centre.
    static func nearest(_ statics: [CGRect], to moving: CGRect) -> [CGRect] {
        guard statics.count > maxStatics else { return statics }
        let centre = CGPoint(x: moving.midX, y: moving.midY)
        return statics
            .sorted {
                hypot($0.midX - centre.x, $0.midY - centre.y)
                    < hypot($1.midX - centre.x, $1.midY - centre.y)
            }
            .prefix(maxStatics)
            .map { $0 }
    }

    /// The equal-spacing positions the moving box could land on, as ordinary
    /// candidate lines ranked with `.layer`.
    ///
    /// Two shapes, both Photoshop's: BETWEEN (M sits between two boxes and
    /// the gaps either side can be equalized) and OUTSIDE (two adjacent
    /// boxes set a rhythm and M continues it). Each candidate is the position
    /// ONE named edge of M must reach, so each carries that edge in
    /// `appliesTo` and `pull` tests it against that coordinate alone.
    ///
    /// Tagging is not a nicety. `pull` is handed M's whole triple and tries
    /// every coordinate against every line, so an untagged BETWEEN candidate
    /// — a position for `minX` — is applied to whichever of `minX`, `midX`
    /// and `maxX` is nearest it. It wins on the WRONG one whenever the
    /// intended correction is outside the pull radius while landing inside
    /// it of one of the other two, which is to say whenever that correction
    /// is near half a box width or a whole one: constantly for a box
    /// narrower than twice the radius (at 25 % zoom the radius is 32 canvas
    /// px, so that is every layer under about 64 px across), and for a box
    /// of any width whose width the correction happens to match. M then
    /// takes a pull to a coordinate that equalizes nothing, and `drawings`,
    /// run on the corrected box, finds no equal gap and draws nothing to
    /// explain it.
    static func spacingCandidates(moving: CGRect, statics: [CGRect]) -> [SnapLine] {
        candidates(moving: moving, statics: statics, axis: .vertical)
            + candidates(moving: moving, statics: statics, axis: .horizontal)
    }

    private static func candidates(
        moving: CGRect, statics: [CGRect], axis: SnapAxis
    ) -> [SnapLine] {
        let boxes = overlapping(statics, with: moving, axis: axis)
            .sorted { start($0, axis) < start($1, axis) }
        guard boxes.count >= 2 else { return [] }
        let mMin = start(moving, axis)
        let mMax = end(moving, axis)
        var lines: [SnapLine] = []

        let before = boxes.filter { end($0, axis) <= mMin + epsilon }
        let after = boxes.filter { start($0, axis) >= mMax - epsilon }

        // BETWEEN: equalize the gap to the nearest neighbour on each side.
        // The position is M's NEAR edge's.
        if let left = before.last, let right = after.first {
            let gapLeft = mMin - end(left, axis)
            let gapRight = start(right, axis) - mMax
            if gapLeft >= -epsilon, gapRight >= -epsilon {
                lines.append(
                    SnapLine(
                        axis: axis, position: mMin + (gapRight - gapLeft) / 2, kind: .layer,
                        appliesTo: startEdge(axis)))
            }
        }
        // OUTSIDE, to the right of a pair: continue their rhythm. Again M's
        // NEAR edge — the one the gap after `b` is measured to.
        if before.count >= 2 {
            let a = before[before.count - 2]
            let b = before[before.count - 1]
            let gap = start(b, axis) - end(a, axis)
            if gap >= -epsilon {
                lines.append(
                    SnapLine(
                        axis: axis, position: end(b, axis) + gap, kind: .layer,
                        appliesTo: startEdge(axis)))
            }
        }
        // OUTSIDE, to the left of a pair: the mirror, landing M's FAR edge.
        if after.count >= 2 {
            let b = after[0]
            let a = after[1]
            let gap = start(a, axis) - end(b, axis)
            if gap >= -epsilon {
                let far = start(b, axis) - gap
                // The candidate is for M's far edge, so it is expressed as
                // the position that edge lands on — and tagged with it, so
                // that is the only coordinate `pull` may apply it to.
                lines.append(
                    SnapLine(
                        axis: axis, position: far, kind: .layer, appliesTo: endEdge(axis)))
            }
        }
        return lines
    }

    /// The moving box's NEAR edge on `axis` — `.left` for a constant-X line,
    /// `.top` for a constant-Y one — in the vocabulary `SnapCoordinate`
    /// tags a translating box's triple with.
    private static func startEdge(_ axis: SnapAxis) -> SnapEdges {
        axis == .vertical ? .left : .top
    }

    /// Its FAR edge, the mirror of `startEdge`.
    private static func endEdge(_ axis: SnapAxis) -> SnapEdges {
        axis == .vertical ? .right : .bottom
    }

    /// Every drawing the CORRECTED box earns: an alignment line for each
    /// coordinate pair that now matches exactly, and a pair of gap bars for
    /// each spacing that is now equal.
    ///
    /// `canvas` bounds the alignment lines' SPANS. A layer may sit partly off
    /// the canvas (a negative offset is legal), and the canvas view force-
    /// overrides `clipsToBounds` to true, so a span reaching past an edge is
    /// drawn nowhere: clipping it here keeps the value the drawing code gets
    /// equal to the ink it actually produces.
    static func drawings(moving: CGRect, statics: [CGRect], canvas: CGSize) -> [SmartGuideLine] {
        guard moving.width.isFinite, moving.height.isFinite else { return [] }
        var out: [SmartGuideLine] = []
        out += alignments(moving: moving, statics: statics, axis: .vertical, canvas: canvas)
        out += alignments(moving: moving, statics: statics, axis: .horizontal, canvas: canvas)
        out += gaps(moving: moving, statics: statics, axis: .vertical)
        out += gaps(moving: moving, statics: statics, axis: .horizontal)
        return out
    }

    private static func alignments(
        moving: CGRect, statics: [CGRect], axis: SnapAxis, canvas: CGSize
    ) -> [SmartGuideLine] {
        var out: [SmartGuideLine] = []
        let mine = coordinates(moving, axis)
        // A `.vertical` line runs along Y, so its span is bounded by the
        // canvas HEIGHT.
        let limit = axis == .vertical ? canvas.height : canvas.width
        for box in statics {
            for theirs in coordinates(box, axis) {
                guard let match = mine.first(where: { abs($0 - theirs) <= epsilon }) else {
                    continue
                }
                let low = max(min(otherStart(moving, axis), otherStart(box, axis)), 0)
                let high = min(max(otherEnd(moving, axis), otherEnd(box, axis)), limit)
                guard low <= high else { continue }
                out.append(.alignment(axis: axis, position: match, span: low...high))
            }
        }
        return out
    }

    private static func gaps(
        moving: CGRect, statics: [CGRect], axis: SnapAxis
    ) -> [SmartGuideLine] {
        let boxes = overlapping(statics, with: moving, axis: axis)
            .sorted { start($0, axis) < start($1, axis) }
        guard boxes.count >= 1 else { return [] }
        let mMin = start(moving, axis)
        let mMax = end(moving, axis)
        let before = boxes.filter { end($0, axis) <= mMin + epsilon }
        let after = boxes.filter { start($0, axis) >= mMax - epsilon }
        var out: [SmartGuideLine] = []

        if let left = before.last, let right = after.first {
            let gapLeft = mMin - end(left, axis)
            let gapRight = start(right, axis) - mMax
            if gapLeft > epsilon, gapRight > epsilon, abs(gapLeft - gapRight) <= epsilon {
                let at = midOfOverlap(moving, left, axis)
                out.append(.spacing(axis: axis, gap: end(left, axis)...mMin, at: at))
                let at2 = midOfOverlap(moving, right, axis)
                out.append(.spacing(axis: axis, gap: mMax...start(right, axis), at: at2))
            }
        }
        if before.count >= 2 {
            let a = before[before.count - 2]
            let b = before[before.count - 1]
            let gapPair = start(b, axis) - end(a, axis)
            let gapMine = mMin - end(b, axis)
            if gapPair > epsilon, gapMine > epsilon, abs(gapPair - gapMine) <= epsilon {
                out.append(
                    .spacing(axis: axis, gap: end(a, axis)...start(b, axis),
                             at: midOfOverlap(a, b, axis)))
                out.append(
                    .spacing(axis: axis, gap: end(b, axis)...mMin,
                             at: midOfOverlap(moving, b, axis)))
            }
        }
        if after.count >= 2 {
            let b = after[0]
            let a = after[1]
            let gapPair = start(a, axis) - end(b, axis)
            let gapMine = start(b, axis) - mMax
            if gapPair > epsilon, gapMine > epsilon, abs(gapPair - gapMine) <= epsilon {
                out.append(
                    .spacing(axis: axis, gap: mMax...start(b, axis),
                             at: midOfOverlap(moving, b, axis)))
                out.append(
                    .spacing(axis: axis, gap: end(b, axis)...start(a, axis),
                             at: midOfOverlap(a, b, axis)))
            }
        }
        return out
    }

    // MARK: Axis helpers — the measuring direction is the axis's own

    /// A `.vertical` line is a constant-X line, so a `.vertical` gap is
    /// measured along X.
    private static func start(_ rect: CGRect, _ axis: SnapAxis) -> CGFloat {
        axis == .vertical ? rect.minX : rect.minY
    }

    private static func end(_ rect: CGRect, _ axis: SnapAxis) -> CGFloat {
        axis == .vertical ? rect.maxX : rect.maxY
    }

    private static func otherStart(_ rect: CGRect, _ axis: SnapAxis) -> CGFloat {
        axis == .vertical ? rect.minY : rect.minX
    }

    private static func otherEnd(_ rect: CGRect, _ axis: SnapAxis) -> CGFloat {
        axis == .vertical ? rect.maxY : rect.maxX
    }

    private static func coordinates(_ rect: CGRect, _ axis: SnapAxis) -> [CGFloat] {
        axis == .vertical
            ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY]
    }

    /// Only boxes that overlap on the PERPENDICULAR axis take part: two
    /// rectangles in different rows have no meaningful horizontal gap.
    private static func overlapping(
        _ statics: [CGRect], with moving: CGRect, axis: SnapAxis
    ) -> [CGRect] {
        statics.filter { box in
            box.width.isFinite && box.height.isFinite
                && otherStart(box, axis) < otherEnd(moving, axis)
                && otherEnd(box, axis) > otherStart(moving, axis)
        }
    }

    /// Where a gap bar is drawn: the middle of the two boxes' shared extent
    /// on the perpendicular axis.
    private static func midOfOverlap(_ a: CGRect, _ b: CGRect, _ axis: SnapAxis) -> CGFloat {
        let low = max(otherStart(a, axis), otherStart(b, axis))
        let high = min(otherEnd(a, axis), otherEnd(b, axis))
        return low <= high ? (low + high) / 2 : (otherStart(a, axis) + otherEnd(a, axis)) / 2
    }
}
