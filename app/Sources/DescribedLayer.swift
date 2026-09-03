import AppKit

// The shared geometry of DESCRIBED layers — text, shapes, Live Photos —
// under a linear map, and the two pure document ops every described-layer
// commit runs through. This file is the reference the three payload files,
// the Free Transform commit, the document-geometry sync and the agent tools
// all point at; the rules below are stated once, here.
//
// THE MODEL. A description carries a 2×2 LINEAR map `transform` (no
// translation) and renders to a raster whose canvas placement is derived
// from an ANCHOR `P`: the canvas image of the description's SOURCE ORIGIN
// (text: the layout origin, the on-canvas editor's frame origin; shape: the
// box's top-left before padding; Live Photo: the still's top-left).
// Translation is never in the payload — it is the core's layer offset — so
// Move, nudges and move_layer stay pure offset changes: `P` moves with the
// offset and nothing in the meta changes.
//
// THE RULE. `P` splits into a whole part and a fraction:
//
//     Pi   = floor(P)                       (per axis)
//     frac = P − Pi                         (∈ [0, 1), stored as origin_frac)
//     rasterRect = outward-rounded bbox of (frac + L·S) [+ slack]   relative to Pi
//     offset     = Pi + rasterRect.origin   (the render rule)
//     P          = offset − rasterRect.origin + frac   (the recovery rule)
//
// where `S` is the padded SOURCE rect (text: the layout rect inset by
// −pad; shape: (0, 0, w, h) inset by −pad; Live Photo: (0, 0, w, h), no
// pad). Under the identity this reproduces the pre-transform rasters
// exactly, fraction included (text: offset = floor(origin) − pad, width =
// ceil(layout.w + frac + 2·pad)); existing files therefore keep their
// rasters, offsets and masks untouched.
//
// THE RENDER. A description draws its source geometry in SOURCE coordinates
// under the CTM `translate(frac − rasterRect.origin) · L` into the shared
// flipped context (`Bitmap.renderStraightRGBA`) and lands at `offset`.
//
// WHOLE PIXELS VS EXACT. Interactive and explicit placements (an editor
// commit, a shape drag, add_*/edit_* x,y) are ROUNDED to whole pixels while
// the description is untransformed — so an untransformed layer stays
// whole-pixel and encodes as version 1, at most 0.5 px from a fractional
// click — and kept exact (1e-9-snapped) once it is transformed. Transform
// compositions (Free Transform, transform_layer, Image Size) move the anchor
// to M·P EXACTLY and snap each element within 1e-9 of an integer, so a
// rotate-back returns the very same anchor and map and re-encodes v1.

/// The 2×2 LINEAR part of a described layer's placement, held in
/// CGAffineTransform element order: (x, y) ↦ (a·x + c·y, b·x + d·y) —
/// exactly `CGAffineTransform(a: b: c: d: tx: 0, ty: 0)` and the first four
/// of the six `rz_doc_transform_layer` takes, so a map drops straight into
/// either without a transpose. Rotation by +θ (clockwise on the y-down
/// canvas) is a = cos θ, b = sin θ, c = −sin θ, d = cos θ, so `b > 0` for a
/// clockwise turn. Translation never lives here.
///
/// ON THE WIRE — the payload's `transform` key and the MCP `transform`
/// argument and report — the four numbers are ROW-MAJOR, `[a, b, c, d]`
/// with x′ = a·x + b·y and y′ = c·x + d·y: the convention a reader writing
/// a matrix by hand expects (and the phase brief's). `init(array:)` and
/// `array` transpose at that boundary and nowhere else, so every internal
/// computation stays in CG order; a clockwise rotation by θ is therefore
/// WRITTEN `[cos θ, −sin θ, sin θ, cos θ]`.
struct LinearMap: Equatable {
    var a: Double
    var b: Double
    var c: Double
    var d: Double

    static let identity = LinearMap(a: 1, b: 0, c: 0, d: 1)

    /// Elements (and mapped coordinates) within this of an integer are
    /// treated as that integer — the core's EXACT_EPSILON (doc_transform.rs),
    /// so the two sides agree on which maps are exact quarter turns and
    /// flips; it is far below anything a drag or an angle field can mean.
    static let epsilon = 1e-9

    init(a: Double, b: Double, c: Double, d: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    /// Exactly four finite numbers in the wire's ROW-MAJOR order (x′ = a·x +
    /// b·y, y′ = c·x + d·y), transposed into CG order here; nil otherwise.
    init?(array: [Double]) {
        guard array.count == 4, array.allSatisfy({ $0.isFinite }) else { return nil }
        self.init(a: array[0], b: array[2], c: array[1], d: array[3])
    }

    /// The wire's ROW-MAJOR `[a, b, c, d]` (the transpose of the CG
    /// elements) with signed zero normalized, so the encoded JSON never
    /// carries "-0" and re-encoding an unchanged map is byte-identical.
    var array: [Double] {
        [a, c, b, d].map { $0 == 0 ? 0 : $0 }
    }

    var cgAffine: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: 0, ty: 0)
    }

    var determinant: Double { a * d - b * c }

    var isFinite: Bool { a.isFinite && b.isFinite && c.isFinite && d.isFinite }

    /// Each element within `epsilon` of the identity's.
    var isIdentity: Bool { matches([1, 0, 0, 1]) }

    /// Finite with `|det| ≥ epsilon` — what the core accepts, and what keeps
    /// a source rect from collapsing to a line.
    var isInvertible: Bool { isFinite && abs(determinant) >= Self.epsilon }

    /// A pixel permutation within `epsilon`: the core's six resample-free
    /// linear forms (identity, flip H, flip V, rotate 180, rotate 90,
    /// rotate 270) plus the two diagonal reflections a flip composed with
    /// a quarter turn produces ([0, 1, 1, 0] and [0, −1, −1, 0]) — maps the
    /// core's geometry ops never emit on their own but their compositions
    /// do. None of them scales, so these are the maps whose raster rects
    /// get no slack (see `rasterRect`): the slack guards a downscale that
    /// shrinks the source-space padding below a canvas pixel, which a
    /// permutation cannot. Listing the diagonal reflections here is what
    /// lets Flip Horizontal then Rotate 90° CW stay a meta-only patch whose
    /// rect is exactly the core's (DescribedLayerGeometry.swift).
    var isExactForm: Bool {
        Self.exactForms.contains { matches($0) }
    }

    /// One of the core's SIX resample-free forms only (`exact_form` in
    /// doc_transform.rs: identity, flip H, flip V, rotate 180, rotate 90,
    /// rotate 270), within `epsilon` — the linear parts under which
    /// `rz_doc_transform_layer`, given a whole-pixel translation, copies
    /// pixels and mask losslessly instead of resampling. Narrower than
    /// `isExactForm`: the two diagonal reflections are permutations too,
    /// but the core resamples them, so a described layer under one
    /// re-renders rather than taking the lossless shortcut
    /// (EditorViewController+DescribedTransform.swift).
    var isResampleFree: Bool {
        Self.exactForms.prefix(6).contains { matches($0) }
    }

    /// The core's six forms in its `exact_form` order, then the two diagonal
    /// reflections. Rotate 90 is the canvas-space map (x, y) ↦ (−y, x), a
    /// clockwise quarter turn on the y-down canvas.
    private static let exactForms: [[Double]] = [
        [1, 0, 0, 1], [-1, 0, 0, 1], [1, 0, 0, -1], [-1, 0, 0, -1],
        [0, 1, -1, 0], [0, -1, 1, 0],
        [0, 1, 1, 0], [0, -1, -1, 0],
    ]

    private func matches(_ form: [Double]) -> Bool {
        abs(a - form[0]) <= Self.epsilon && abs(b - form[1]) <= Self.epsilon
            && abs(c - form[2]) <= Self.epsilon && abs(d - form[3]) <= Self.epsilon
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x)
        let y = Double(p.y)
        return CGPoint(x: a * x + c * y, y: b * x + d * y)
    }

    /// nil when not invertible.
    func inverted() -> LinearMap? {
        guard isInvertible else { return nil }
        let det = determinant
        return LinearMap(a: d / det, b: -b / det, c: -c / det, d: a / det)
    }

    /// self first, then `m`'s linear part (its translation is dropped —
    /// translation moves the anchor instead):
    ///
    ///     L′.a = M.a·L.a + M.c·L.b      L′.c = M.a·L.c + M.c·L.d
    ///     L′.b = M.b·L.a + M.d·L.b      L′.d = M.b·L.c + M.d·L.d
    ///
    /// which is `cgAffine.concatenating(m)` with tx/ty ignored.
    func concatenating(_ m: CGAffineTransform) -> LinearMap {
        concatenating(LinearMap(a: Double(m.a), b: Double(m.b), c: Double(m.c), d: Double(m.d)))
    }

    /// self first, then `m` (the formula above).
    func concatenating(_ m: LinearMap) -> LinearMap {
        LinearMap(
            a: m.a * a + m.c * b,
            b: m.b * a + m.d * b,
            c: m.a * c + m.c * d,
            d: m.b * c + m.d * d)
    }

    /// Each element within `epsilon` of an integer snapped onto it (the
    /// core's `snap_to_integer` idea), so a quarter turn composed from an
    /// angle — where cos returns 6e-17 instead of 0 — is recognized as the
    /// exact form it is and a rotate-back yields the identity exactly; −0
    /// becomes 0 so the encoded JSON is canonical.
    func snapped() -> LinearMap {
        LinearMap(
            a: Self.snap(a), b: Self.snap(b), c: Self.snap(c), d: Self.snap(d))
    }

    /// A coordinate within `epsilon` of an integer, snapped onto it; the
    /// value is otherwise untouched. Signed zero is normalized.
    static func snap(_ v: Double) -> Double {
        guard v.isFinite else { return v }
        let rounded = v.rounded()
        let result = abs(v - rounded) <= epsilon ? rounded : v
        return result == 0 ? 0 : result
    }

    /// The outward-rounded raster rect of `fraction + self·source`, relative
    /// to the anchor's whole part: the four corners of `source` mapped
    /// through the map, `fraction` added, each coordinate snapped within
    /// `epsilon` of an integer (so a composed quarter turn cannot grow a
    /// phantom column), then origin = floor(min), size = ceil(max) −
    /// floor(min) per axis.
    ///
    /// SLACK: unless the map is one of the six exact forms, the rect grows
    /// by 1 canvas px on every side. The source-space padding of text and
    /// shapes is sized for the identity; a downscale shrinks it below a
    /// canvas pixel and would clip the antialiased edge of the outermost
    /// glyph or stroke. Exact forms keep the pre-transform rects (legacy
    /// files and the meta-only rotate/flip sync rely on that equality);
    /// non-exact maps are version 2 anyway, so nothing depends on their
    /// rect matching a prior raster.
    ///
    /// nil when non-finite, empty, outside Int32, or over
    /// `RasterImage.maxResizePixels`.
    func rasterRect(of source: CGRect, fraction: CGPoint)
        -> (originX: Int, originY: Int, width: Int, height: Int)?
    {
        guard isFinite, fraction.x.isFinite, fraction.y.isFinite,
              source.origin.x.isFinite, source.origin.y.isFinite,
              source.width.isFinite, source.height.isFinite
        else { return nil }
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for corner in Self.corners(of: source) {
            let mapped = apply(corner)
            let x = Self.snap(Double(mapped.x + fraction.x))
            let y = Self.snap(Double(mapped.y + fraction.y))
            guard x.isFinite, y.isFinite else { return nil }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        var left = minX.rounded(.down)
        var top = minY.rounded(.down)
        var right = maxX.rounded(.up)
        var bottom = maxY.rounded(.up)
        if !isExactForm {
            left -= 1
            top -= 1
            right += 1
            bottom += 1
        }
        let int32Min = Double(Int32.min)
        let int32Max = Double(Int32.max)
        guard left >= int32Min, top >= int32Min, right <= int32Max, bottom <= int32Max
        else { return nil }
        let width = right - left
        let height = bottom - top
        guard width >= 1, height >= 1,
              width * height <= Double(RasterImage.maxResizePixels)
        else { return nil }
        return (Int(left), Int(top), Int(width), Int(height))
    }

    /// The mapped corners of `rect` (TL, TR, BR, BL) plus `anchor` — the
    /// canvas quad a description's source rect lands on.
    func quad(of rect: CGRect, anchor: CGPoint) -> [CGPoint] {
        Self.corners(of: rect).map { corner in
            let mapped = apply(corner)
            return CGPoint(x: mapped.x + anchor.x, y: mapped.y + anchor.y)
        }
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }
}

/// A rendered description: a TIGHT straight-alpha RGBA8 raster (row 0 =
/// top, exactly `width * height * 4` bytes) plus the canvas-space offset the
/// layer must take for the rendering to land where its anchor says.
struct DescribedRaster {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let offsetX: Int
    let offsetY: Int
}

/// The three kinds a description can be, named by the `type` its meta
/// carries — what a destructive edit drops and what the rasterize prompt
/// names, whether or not this build can decode the rest of the payload.
enum DescribedKind: String {
    case text
    case shape
    case livePhoto = "live_photo"
}

/// One of the three re-openable descriptions a layer's meta can hold. The
/// meta is ONE slot, so the kinds are mutually exclusive; the decode order
/// (text, shape, Live Photo) only matters for a blob no kind should accept.
enum LayerDescription: Equatable {
    case text(TextLayerPayload)
    case shape(ShapeLayerPayload)
    case livePhoto(LivePhotoPayload)

    /// The description `meta` encodes, or nil for a plain raster layer, an
    /// adjustment layer, or metadata this app does not recognize.
    static func decode(_ meta: String?) -> LayerDescription? {
        guard let meta = meta else { return nil }
        if let payload = TextLayerPayload.decode(meta) { return .text(payload) }
        if let payload = ShapeLayerPayload.decode(meta) { return .shape(payload) }
        if let payload = LivePhotoPayload.decode(meta) { return .livePhoto(payload) }
        return nil
    }

    /// The kind `meta` CLAIMS by its top-level `type` — "text", "shape" or
    /// "live_photo" — whatever its version, or nil for anything else. This
    /// is what the destructive-edit gate asks (`ImageDocument.
    /// layerDescribesSource`, the agent's `performPixelEdit`), not `decode`:
    /// a description this build cannot decode (a payload version it does
    /// not know — one written by a newer build, or by this one and read back
    /// by an older one) still describes the pixels it was rendered for, so a
    /// destructive edit must drop it exactly as it drops one it can read.
    /// Left in place, it would survive the paint and the next build to
    /// understand it would read a description that no longer describes the
    /// pixels. A build that shipped without this rule cannot be fixed
    /// retroactively: a file it painted over keeps its stale description,
    /// and reopening that layer here re-renders the description over the
    /// paint.
    static func claimedKind(of meta: String?) -> DescribedKind? {
        guard let meta = meta, let data = meta.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        return DescribedKind(rawValue: type)
    }

    var kind: DescribedKind {
        switch self {
        case .text: return .text
        case .shape: return .shape
        case .livePhoto: return .livePhoto
        }
    }

    var transform: LinearMap {
        switch self {
        case let .text(payload): return payload.transform
        case let .shape(payload): return payload.transform
        case let .livePhoto(payload): return payload.transform
        }
    }

    var originFraction: CGPoint {
        switch self {
        case let .text(payload): return payload.originFraction
        case let .shape(payload): return payload.originFraction
        case let .livePhoto(payload): return payload.originFraction
        }
    }

    func withTransform(_ map: LinearMap) -> LayerDescription {
        switch self {
        case var .text(payload):
            payload.transform = map
            return .text(payload)
        case var .shape(payload):
            payload.transform = map
            return .shape(payload)
        case var .livePhoto(payload):
            payload.transform = map
            return .livePhoto(payload)
        }
    }

    func withOriginFraction(_ frac: CGPoint) -> LayerDescription {
        switch self {
        case let .text(payload): return .text(payload.withOriginFraction(frac))
        case let .shape(payload): return .shape(payload.withOriginFraction(frac))
        case let .livePhoto(payload): return .livePhoto(payload.withOriginFraction(frac))
        }
    }

    func json() -> String? {
        switch self {
        case let .text(payload): return payload.json()
        case let .shape(payload): return payload.json()
        case let .livePhoto(payload): return payload.json()
        }
    }

    /// "text" | "shape" | "live_photo" — the get_document key.
    var kindName: String { kind.rawValue }

    /// Whether a re-render right now would reproduce the description
    /// faithfully: text needs its family installed (a fallback face would
    /// silently re-set a headline), a shape always can, a Live Photo needs
    /// the very source its frame is drawn from to decode (a probe decode,
    /// `LivePhotoPayload.isRenderable`: the still at the key moment, the
    /// clip's frame elsewhere — never the upscaled video frame the explicit
    /// frame pick falls back to when the still is gone). An explicit edit
    /// still renders an unrenderable text layer with the fallback face — the
    /// user asked for a re-render — but no geometry op may re-render one
    /// behind the user's back: Free Transform prompts and resamples the real
    /// pixels instead, and Image Size patches the meta over the core's
    /// resample. The Live Photo check costs a small decode, so callers that
    /// loop over every layer ask it last, after their cheaper checks.
    var isRenderable: Bool {
        switch self {
        case let .text(payload): return payload.style.isInstalled
        case .shape: return true
        case let .livePhoto(payload): return payload.isRenderable
        }
    }

    /// A text description with a LEGACY unspecified box resolved FROM THE
    /// RASTER it was rendered into — `rasterWidth` is the layer's pixel
    /// width, and `TextLayer.boxWidth(fittingRasterWidth:size:)` recovers a
    /// box that reproduces the raster's own line breaks, where the
    /// pre-change defaults (`TextLayer.legacyBoxWidth`, the agent's
    /// canvas-edge rule) are guesses that re-wrap a title whose real width
    /// was different; every other description unchanged. Every path that
    /// rewrites a legacy layer's meta materializes the box FIRST, so an
    /// unspecified box never coexists with a non-identity transform — which
    /// is also why the raster of an unspecified box is always an identity
    /// raster, the layout's width plus the padding.
    func resolved(rasterWidth: Int) -> LayerDescription {
        guard case let .text(payload) = self, payload.box == .unspecified else { return self }
        let width = TextLayer.boxWidth(fittingRasterWidth: rasterWidth, size: payload.size)
        return .text(payload.resolvingLegacyBox(width: width))
    }

    /// The padded SOURCE rect the rendering covers (see the rule at the top
    /// of the file); nil for a text box that is still unresolved (there is
    /// no layout to measure) or a string that lays out to nothing.
    func sourceRect() -> CGRect? {
        switch self {
        case let .text(payload): return TextLayer.sourceRect(payload)
        case let .shape(payload): return ShapeLayer.sourceRect(payload)
        case let .livePhoto(payload): return LivePhoto.sourceRect(payload)
        }
    }

    /// `transform.rasterRect(of: sourceRect, fraction: originFraction)`;
    /// nil when the source rect is (an unresolved text box).
    func rasterRect() -> (originX: Int, originY: Int, width: Int, height: Int)? {
        guard let source = sourceRect() else { return nil }
        return transform.rasterRect(of: source, fraction: originFraction)
    }

    /// The raster rect's origin relative to the anchor's whole part — what
    /// the recovery rule needs. For a text box that is still unresolved it
    /// is (−pad, −pad) under the identity: the left-aligned layout's origin
    /// is (0, 0) whatever the wrap width, so the raster origin does not
    /// depend on the width, which is what lets a legacy file's anchor,
    /// reopen and get_document work without a canvas width. Under any other
    /// map it is nil — and no writer ever produces that combination.
    func rasterOrigin() -> (x: Int, y: Int)? {
        rasterOrigin(source: sourceRect())
    }

    /// `rasterOrigin()` over a source rect already measured: `source` must
    /// be what `sourceRect()` returns (nil included), so a caller that needs
    /// the rect as well — the transform commit, whose text layout is the
    /// expensive part — lays the text out once instead of once per question.
    func rasterOrigin(source: CGRect?) -> (x: Int, y: Int)? {
        if let source = source,
           let rect = transform.rasterRect(of: source, fraction: originFraction)
        {
            return (rect.originX, rect.originY)
        }
        guard case let .text(payload) = self, payload.box == .unspecified,
              transform.isIdentity
        else { return nil }
        let pad = TextLayer.padding(forSize: payload.size)
        return (-pad, -pad)
    }

    /// The recovery rule: P = offset − rasterRect.origin + originFraction.
    func anchor(offsetX: Int, offsetY: Int) -> CGPoint? {
        anchor(offsetX: offsetX, offsetY: offsetY, source: sourceRect())
    }

    /// The recovery rule over a source rect already measured (the contract
    /// of `rasterOrigin(source:)`).
    func anchor(offsetX: Int, offsetY: Int, source: CGRect?) -> CGPoint? {
        guard let origin = rasterOrigin(source: source) else { return nil }
        return CGPoint(
            x: CGFloat(offsetX - origin.x) + originFraction.x,
            y: CGFloat(offsetY - origin.y) + originFraction.y)
    }

    /// Renders through the kind's renderer at `anchor`; the renderer takes
    /// the fraction from the anchor, so a description's stored
    /// `origin_frac` never has to agree with the anchor it is rendered at.
    func render(anchor: CGPoint) -> DescribedRaster? {
        switch self {
        case let .text(payload): return TextLayer.render(payload, anchor: anchor)
        case let .shape(payload): return ShapeLayer.render(payload, anchor: anchor)
        case let .livePhoto(payload): return LivePhoto.render(payload, anchor: anchor)
        }
    }
}

/// The anchor arithmetic and the mask re-crop every described-layer commit
/// shares.
enum DescribedLayer {
    /// `p − floor(p)` per axis: the part of an anchor that rides inside the
    /// raster (∈ [0, 1)).
    static func anchorFraction(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - p.x.rounded(.down), y: p.y - p.y.rounded(.down))
    }

    /// Each coordinate within 1e-9 of an integer snapped onto it — the
    /// core's `snap_to_integer` rule — so a transform composition that
    /// returns an anchor to where it started returns it EXACTLY, and a
    /// quarter turn about a half-integer pivot keeps its half-pixel anchor
    /// instead of drifting.
    static func snappedAnchor(_ p: CGPoint) -> CGPoint {
        CGPoint(x: LinearMap.snap(Double(p.x)), y: LinearMap.snap(Double(p.y)))
    }

    /// Interactive and explicit placements (an editor commit, a shape drag
    /// or re-box, add_*/edit_* x,y): rounded to whole pixels when
    /// `transform` is the identity — an untransformed layer stays
    /// whole-pixel and encodes as v1, at most 0.5 px from a fractional
    /// click, today's floor/round behaviour — and the exact snapped point
    /// when it is transformed (a re-box on a rotated shape keeps its
    /// un-dragged corner pinned exactly).
    static func placementAnchor(_ p: CGPoint, transform: LinearMap) -> CGPoint {
        guard transform.isIdentity else { return snappedAnchor(p) }
        return CGPoint(x: p.x.rounded(), y: p.y.rounded())
    }

    /// An interactive re-placement of an EXISTING description — a shape
    /// re-edit's commit: `from` is the layer's current exact anchor, `to`
    /// where the session's drags left it. Untouched, the anchor is kept
    /// EXACTLY: a restyle from the options bar must neither nudge the
    /// shape nor lose a fraction a transform composition left behind under
    /// a map that has since snapped back to the identity (the text
    /// commit's rule, EditorViewController+Text.swift). Moved, the
    /// placement rule above applies to the DELTA the drag introduced —
    /// whole pixels under the identity, so an untransformed layer stays
    /// whole-pixel and version 1; exact under a map — never to a
    /// pre-existing fraction.
    static func placementAnchor(from: CGPoint, to: CGPoint, transform: LinearMap) -> CGPoint {
        guard to != from else { return from }
        guard transform.isIdentity else { return snappedAnchor(to) }
        return CGPoint(
            x: from.x + (to.x - from.x).rounded(), y: from.y + (to.y - from.y).rounded())
    }

    /// The most a raster's size may differ from the rule's rect, per axis,
    /// and still be that description's rendering: a text raster saved
    /// before anchor fractions were recorded kept the fraction INSIDE the
    /// raster, so it is up to one pixel larger than the rule's, and a
    /// layout measured by another build rounds the same way. Beyond it the
    /// raster is NOT this description's rendering — a layer an earlier
    /// build's Image Size resampled while its description kept its
    /// original size (the pre-phase known limit) — and no path may
    /// silently re-render, re-fit or re-box it: the document geometry ops
    /// patch its meta only (DescribedLayerGeometry.swift) and Free
    /// Transform / transform_layer take the rasterize path
    /// (`describedTransformPlacement`), as they do for any raster.
    static let rasterTolerance = 1

    /// Whether a `width × height` raster can be the rendering of a
    /// description whose rule's rect is `rect` — within `rasterTolerance`
    /// on each axis.
    static func rasterAgrees(
        width: Int, height: Int,
        with rect: (originX: Int, originY: Int, width: Int, height: Int)
    ) -> Bool {
        abs(width - rect.width) <= rasterTolerance && abs(height - rect.height) <= rasterTolerance
    }

    /// `plane` (a u8 coverage plane covering canvas rect `from`, row 0 =
    /// top) re-cropped by canvas position into `to`. A position outside
    /// `from` reads the NEAREST in-range sample (edge extension): the
    /// anchor rounding can push a re-render's rect one pixel past the
    /// core's on a side, and zero-filling there would mask out the
    /// outermost real row of a pad-0 Live Photo; for the transparent
    /// padding of text and shapes the extension is a no-op. Pure byte
    /// copying. A `from` with no samples yields an all-revealing plane.
    static func recrop(
        _ plane: [UInt8], from: (x: Int, y: Int, w: Int, h: Int),
        to: (x: Int, y: Int, w: Int, h: Int)
    ) -> [UInt8] {
        guard to.w > 0, to.h > 0 else { return [] }
        guard from.w > 0, from.h > 0, plane.count == from.w * from.h else {
            return [UInt8](repeating: 255, count: to.w * to.h)
        }
        var out = [UInt8](repeating: 0, count: to.w * to.h)
        for row in 0..<to.h {
            let sourceRow = min(max(to.y + row - from.y, 0), from.h - 1)
            let sourceBase = sourceRow * from.w
            let outBase = row * to.w
            for column in 0..<to.w {
                let sourceColumn = min(max(to.x + column - from.x, 0), from.w - 1)
                out[outBase + column] = plane[sourceBase + sourceColumn]
            }
        }
        return out
    }
}

extension RasterDocument {
    /// Layer `idx`'s description, or nil for a plain raster layer.
    func layerDescription(_ idx: Int) -> LayerDescription? {
        LayerDescription.decode(layerMeta(idx))
    }

    /// The exact anchor of layer `idx`'s description (the recovery rule);
    /// nil for a plain raster layer, or a legacy text box under a
    /// non-identity map — which no writer produces.
    func describedAnchor(_ idx: Int) -> CGPoint? {
        guard let description = layerDescription(idx), let info = layerInfo(idx) else {
            return nil
        }
        return description.anchor(offsetX: info.offsetX, offsetY: info.offsetY)
    }

    /// Whether layer `idx`'s raster is NOT its description's rendering: the
    /// description decodes and its rule's rect can be trusted, yet the
    /// raster's size disagrees with that rect by more than
    /// `DescribedLayer.rasterTolerance` — pixels an earlier build's Image
    /// Size resampled while the description kept its original size. What
    /// the rasterize prompt and the agent's note name as the reason. False
    /// for a plain layer, a text family not installed here (the rule would
    /// measure the fallback face, so the sizes are not comparable), or a
    /// rect that cannot be computed.
    func describedRasterIsStale(_ idx: Int) -> Bool {
        guard let raw = layerDescription(idx), let info = layerInfo(idx) else { return false }
        if case .text = raw, !raw.isRenderable { return false }
        guard let rect = raw.resolved(rasterWidth: info.width).rasterRect() else { return false }
        return !DescribedLayer.rasterAgrees(width: info.width, height: info.height, with: rect)
    }

    /// A new layer above `below` rendered from `description` at `anchor`,
    /// described, in one handle (addingLayer → setLayerContent with no mask
    /// → withLayerMeta). Stamps frac(anchor) into the description before
    /// encoding — callers never write `origin_frac` themselves.
    func addingDescribedLayer(
        above below: Int, _ description: LayerDescription, anchor: CGPoint, name: String
    ) -> RasterDocument? {
        guard let raster = description.render(anchor: anchor),
              let meta = description.withOriginFraction(
                DescribedLayer.anchorFraction(anchor)).json()
        else { return nil }
        let idx = below + 1
        // The core has no "layer from a buffer" constructor: add an empty
        // layer, then give it the rendered pixels, its offset and its
        // description — all pure, all in one handle.
        return addingLayer(above: below, name: name)?
            .setLayerContent(
                idx, rgba: raster.pixels, width: raster.width, height: raster.height,
                offsetX: raster.offsetX, offsetY: raster.offsetY, mask: nil)?
            .withLayerMeta(idx, meta)
    }

    /// Re-renders layer `idx` from `description` at `anchor` in place:
    /// pixels, offset and meta replaced (frac(anchor) stamped), and the
    /// layer's CURRENT mask (self's, at self's rect) re-cropped by canvas
    /// position into the new rect — one handle. Callers that transformed or
    /// resized the document first call this ON that result, so the mask
    /// (and style) they carry are the ones that land: the core's resampled
    /// mask sits at a rect within a pixel or two of the re-render's, which
    /// `recrop`'s edge extension absorbs.
    func rerenderingDescribedLayer(
        _ idx: Int, _ description: LayerDescription, anchor: CGPoint
    ) -> RasterDocument? {
        guard let info = layerInfo(idx),
              let raster = description.render(anchor: anchor),
              let meta = description.withOriginFraction(
                DescribedLayer.anchorFraction(anchor)).json()
        else { return nil }
        let mask: [UInt8]? = layerHasMask(idx)
            ? layerMaskCoverage(idx).map {
                DescribedLayer.recrop(
                    $0, from: (info.offsetX, info.offsetY, info.width, info.height),
                    to: (raster.offsetX, raster.offsetY, raster.width, raster.height))
            }
            : nil
        return setLayerContent(
            idx, rgba: raster.pixels, width: raster.width, height: raster.height,
            offsetX: raster.offsetX, offsetY: raster.offsetY, mask: mask)?
            .withLayerMeta(idx, meta)
    }
}
