import AppKit

// Whole-document geometry and the described layers it moves: Rotate
// 90/180/270, Flip H/V and Image Size compose their linear map into every
// text, shape and Live Photo description (DescribedLayer.swift), so a
// re-edit after one lands where the pixels are — turned, mirrored or
// scaled with them — instead of upright at the layer's corner. Shared by
// the Image menu (EditorViewController), the Image Size sheet (Sheets.swift)
// and the agent's rotate / flip / image_size (AgentServer), which all run
// the one op below. Crop, Canvas Size and the straightening crop are
// untouched: the first two only shift offsets, which the anchor follows for
// free; straighten still asks and rasterizes (a follow-on).
//
// THE PIPELINE — one pure op, one handle, one undo step:
//
//   1. NORMALIZE, before the core touches a pixel. Every described layer is
//      brought onto the render rule of DescribedLayer.swift: a legacy text
//      box is materialized FROM ITS RASTER (`LayerDescription.resolved`,
//      which recovers a box that reproduces the raster's own line breaks —
//      so an unspecified box never meets a non-identity map, and a title
//      is never re-wrapped at a guessed width), and a raster that is ONE
//      PIXEL off what its description renders to — the only disagreement a
//      rendering can carry (`DescribedLayer.rasterTolerance`): a text layer
//      saved before anchor fractions were recorded kept the fraction inside
//      the raster, so it is up to 1 px wider than the rule's, and a legacy
//      raster's layout was measured by another build — is first RE-FITTED
//      onto the rule's rect by lossless byte copying (the safety net below,
//      run early; the extra fraction column is transparent) and only
//      re-rendered in place at its own anchor when the refit would cost
//      ink. Re-rendering, the last resort, is exactly what the layer's
//      first reopen would do, so nothing is lost that a re-edit would not
//      lose. A raster that disagrees by MORE than that is not this
//      description's rendering at all — a layer an earlier build's Image
//      Size resampled while the description kept its original size (the
//      pre-change known limit) — and is STALE: nothing may re-render,
//      re-fit or re-box it behind the user's back (a re-render would drop a
//      block twice the size the user sees, wrapped at a box recovered from
//      the wrong width, into a supposedly lossless rotate), so its pixels
//      stay exactly as the core moves them and only the map composes, with
//      the fraction reset; its legacy box, if any, takes the pre-change
//      default (`TextLayer.legacyBoxWidth`, what its next reopen wraps at
//      anyway) rather than one read off a resampled width. A description
//      that must not render behind the user's back (`isRenderable` false: a
//      font not installed here, a Live Photo whose source will not decode)
//      is left as is — and a text layer whose family is missing is not
//      even COMPARED with the rule, let alone re-fitted onto it: the rule
//      would measure the fallback face, and a raster padded or trimmed to
//      that face's rect would carry the wrong offset back to the machine
//      that has the font (`hasTrustworthyRect`, below). A meta that CLAIMS
//      a described kind but cannot be used — a payload version this build
//      does not decode, a description whose anchor cannot be recovered — is
//      DROPPED inside the same edit, the rule every paint path follows
//      (`ImageDocument.layerDescribesSource`, `AgentServer.performPixelEdit`):
//      left in place it would go on describing pixels the core has since
//      turned, mirrored or scaled.
//   2. THE CORE OP. rotate/flip move every pixel and mask losslessly and
//      remap offsets; resize resamples them all and scales layer styles.
//   3. COMPOSE. Every captured description takes L′ = L ∘ G — its own map
//      first, then the op's — and its anchor moves to the op's image of P,
//      G·P + t, snapped within 1e-9 of an integer like every transform
//      composition (`DescribedLayer.snappedAnchor`), so four quarter turns
//      bring a whole-pixel anchor back to exactly itself.
//
// WHY ROTATE/FLIP NEED NO RE-RENDER (the meta-only patch). With the raster
// on the rule — offset = floor(P) + floor(bmin), size = ceil(bmax) −
// floor(bmin) per axis over frac + L·S after the 1e-9 snap — the core's
// exact op produces the very pixels the composed description renders to,
// at the very offset the rule gives for P′. Rotate 90: the core sets
// offset′ = (ch − oy − lh, ox); the rule with P′ = (ch − P.y, P.x) and
// L′ = L ∘ [0, 1, −1, 0] — whose x-range is the negated y-range of L·S —
// gives floor(P′.x) + floor(bmin′.x) = ch − (Pi.y + floor(frac.y + bmin.y))
// − lh = ch − oy − lh, and floor(P′.y) + floor(bmin′.y) = Pi.x +
// floor(frac.x + bmin.x) = ox. The snap-then-floor/ceil rounding is what
// makes −ceil(v) = floor(−v) exact; the other four ops follow the same
// pattern, and the 1 px slack a non-exact map carries is symmetric, so it
// survives too. The meta therefore only needs the composed map and the new
// anchor's fraction; the anchor itself is DERIVED from the core's offset by
// the recovery rule, so nothing is asserted at runtime and the pixels stay
// the core's lossless copies. (Fuzzed over 100 000 random anchors, source
// rects and maps against the core's offset formulas before this shipped.)
//
// DIAGONAL REFLECTIONS. A flip composed with a quarter turn (Flip
// Horizontal, then Rotate 90° CW — or the map of a layer that was already
// one of them) is a reflection across a diagonal, [0, 1, 1, 0] or
// [0, −1, −1, 0]: a pixel permutation the core's geometry ops never emit on
// their own, which is why `LinearMap.isExactForm` lists the two alongside
// the core's six. It never scales, so the rule gives its raster no slack
// and the core's turned raster IS the rule's, like every other exact
// composition — without that listing the rule's rect would carry 1 px of
// slack per side the core's raster lacks and the recovered anchor would
// sit (1, 1) off.
//
// THE SAFETY NET. After every exact op the core's raster is nevertheless
// RE-FITTED onto the rule's rect whenever the two disagree and the refit
// loses nothing: transparent padding where the rule's rect is larger, and
// a crop only through rows and columns that carry no ink (pure byte
// copying; the mask re-cropped edge-extending). Pixels stay the core's
// copies, it needs no font or file, and it repairs any disagreement that
// costs no ink — a legacy raster's extra transparent column. Only a
// disagreement that would drop ink is left as the core made it, its
// anchor a little off until its next explicit re-render. It runs only for
// a raster the normalization found ON the rule (within the tolerance): a
// text layer whose family is not installed here is never re-fitted at
// all — its rule's rect is the FALLBACK face's, not the one its raster was
// rendered to, so a refit onto it (padding to a taller substitute layout,
// say) would make the core's offset encode the substitute's geometry, and
// on the machine that has the real font the recovered anchor would sit a
// line's difference off the ink — whereas the raster left exactly as the
// core made it keeps the offset consistent with the real face's rule,
// since only the size, never the origin, depends on the face. Such a
// layer takes the map-and-fraction patch only. A STALE raster (above) is
// never re-fitted either: the rule's rect is a size its pixels never had.
//
// WHY IMAGE SIZE RE-RENDERS TEXT AND SHAPES BUT NOT LIVE PHOTOS. A resample
// of a text raster is soft; drawing the glyphs and paths through the scaled
// map is crisp, so a renderable text or shape description is re-rendered
// at P′ = (P.x·fx, P.y·fy) on the resized document, with the core's
// resampled mask re-cropped into the new rect (edge-extending, so the
// pixel or two by which the core's rounded rect and the rule's disagree
// costs no real row) and the core's scaled style kept. That is one extra
// CoreGraphics pass per text/shape layer on top of the core's resample —
// unavoidable, since the core resamples every layer before it hands the
// document back. A Live Photo has no crispness to gain over the core's
// high-quality resample, and decoding a full-resolution still or video
// frame synchronously inside every Image Size is not worth it, so it —
// like an unrenderable description, or one whose re-render the core
// refuses — takes the META-PATCH fallback: the core's resampled pixels
// stay, the meta gets the scaled map, and the raster is re-fitted onto the
// rule's rect at P′ by the same lossless refit, so the recovered anchor is
// P′ itself and the next explicit re-render (a frame pick, a text edit with
// a substituted face) lands within the resample's half-pixel rounding.
// When even that refit would cost ink — or the rule's rect cannot be
// trusted, a text layer whose family is missing, or the raster is stale —
// the fraction is reset to zero and the anchor is whatever the core's
// offset implies — honest to within a pixel or two, and for a stale raster
// exactly the relation it had before the op: the description's block and
// the resampled pixels share a top-left corner, in the new orientation.

/// A whole-document geometry op and what it does to every described layer's
/// map.
enum DocumentGeometry {
    case rotate90
    case rotate180
    case rotate270
    case flipHorizontal
    case flipVertical
    case resize(width: Int, height: Int, filter: RzResizeFilter)

    /// The undo action name — the Image menu's own titles.
    var actionName: String {
        switch self {
        case .rotate90: return "Rotate 90° CW"
        case .rotate270: return "Rotate 90° CCW"
        case .rotate180: return "Rotate 180°"
        case .flipHorizontal: return "Flip Horizontal"
        case .flipVertical: return "Flip Vertical"
        case .resize: return "Image Size"
        }
    }

    /// Whether the core moves pixels losslessly (the five rotate/flip ops):
    /// those produce exactly the pixels a re-render would, so a description
    /// only needs its meta patched. A resize resamples.
    var isExact: Bool {
        if case .resize = self { return false }
        return true
    }

    /// The canvas→canvas LINEAR part of the op on a `canvasWidth ×
    /// canvasHeight` canvas, in CGAffineTransform order (DescribedLayer.swift)
    /// — the `G` every description composes with. Rotate 90 is
    /// (x, y) ↦ (−y, x), a clockwise quarter turn on the y-down canvas and
    /// exactly the core's `Geometry::Rotate90`; the resize factors are the
    /// new size over the old, the core's own `fx`/`fy`.
    func linearMap(canvasWidth: Int, canvasHeight: Int) -> LinearMap {
        switch self {
        case .rotate90: return LinearMap(a: 0, b: 1, c: -1, d: 0)
        case .rotate180: return LinearMap(a: -1, b: 0, c: 0, d: -1)
        case .rotate270: return LinearMap(a: 0, b: -1, c: 1, d: 0)
        case .flipHorizontal: return LinearMap(a: -1, b: 0, c: 0, d: 1)
        case .flipVertical: return LinearMap(a: 1, b: 0, c: 0, d: -1)
        case let .resize(width, height, _):
            // A document is never 0 wide or high; the max only keeps the
            // factor finite should one ever be.
            return LinearMap(
                a: Double(width) / Double(max(canvasWidth, 1)), b: 0, c: 0,
                d: Double(height) / Double(max(canvasHeight, 1)))
        }
    }

    /// The translation that, with `linearMap`, makes the op's FULL
    /// canvas→canvas map: a quarter turn or a flip pushes the canvas back
    /// into the positive quadrant by the old height or width (the core's
    /// offset rule, `(ch − oy − lh, ox)` for rotate 90, is this map applied
    /// to a layer's far corner); a resize scales about the origin.
    func translation(canvasWidth: Int, canvasHeight: Int) -> CGPoint {
        let cw = CGFloat(canvasWidth)
        let ch = CGFloat(canvasHeight)
        switch self {
        case .rotate90: return CGPoint(x: ch, y: 0)
        case .rotate180: return CGPoint(x: cw, y: ch)
        case .rotate270: return CGPoint(x: 0, y: cw)
        case .flipHorizontal: return CGPoint(x: cw, y: 0)
        case .flipVertical: return CGPoint(x: 0, y: ch)
        case .resize: return .zero
        }
    }

    /// Where canvas point `p` lands after the op — `linearMap · p +
    /// translation`, the full map with its translation, which is what an
    /// anchor moves by. Rotate 90 sends (x, y) to (ch − y, x); rotate 180
    /// to (cw − x, ch − y); rotate 270 to (y, cw − x); flip H to (cw − x, y);
    /// flip V to (x, ch − y); a resize to (x·fx, y·fy).
    func apply(_ p: CGPoint, canvasWidth: Int, canvasHeight: Int) -> CGPoint {
        let mapped = linearMap(canvasWidth: canvasWidth, canvasHeight: canvasHeight).apply(p)
        let shift = translation(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        return CGPoint(x: mapped.x + shift.x, y: mapped.y + shift.y)
    }

    /// The core op alone (pixels, masks, offsets, styles); nil exactly when
    /// the core refuses (a resize past its pixel cap).
    func perform(on doc: RasterDocument) -> RasterDocument? {
        switch self {
        case .rotate90: return doc.rotated90()
        case .rotate180: return doc.rotated180()
        case .rotate270: return doc.rotated270()
        case .flipHorizontal: return doc.flippedH()
        case .flipVertical: return doc.flippedV()
        case let .resize(width, height, filter):
            return doc.resized(w: width, h: height, filter: filter)
        }
    }
}

private extension LayerDescription {
    /// Whether Image Size draws this description afresh through the scaled
    /// map: text and shapes gain crisp edges over a resample and may render
    /// unprompted (`isRenderable`); a Live Photo never does here — see the
    /// file comment.
    var rerendersOnResize: Bool {
        if case .livePhoto = self { return false }
        return isRenderable
    }

    /// Whether the raster's SIZE may be compared with — and re-fitted onto
    /// — the rule's rect: false for a text description whose family is not
    /// installed here, where the rule measures the FALLBACK face's layout.
    /// That rect is not the one the raster was rendered to, so a refit
    /// onto it would pad or trim the raster to the substitute's size and
    /// leave the core's offset encoding the substitute's geometry on the
    /// machine that has the font — a silent violation of "the meta
    /// describes the current pixels" that the raster left alone never
    /// commits, because the core's exact ops keep its offset consistent
    /// with the real face's rule. Only such a layout's ORIGIN is
    /// font-independent (and only under the identity), which is all the
    /// anchor recovery needs. A shape's rect is exact and a Live Photo's is
    /// its payload's own size, so both are always trustworthy — no probe
    /// decode is needed to say so.
    var hasTrustworthyRect: Bool {
        if case .text = self { return isRenderable }
        return true
    }
}

/// How far a captured layer's raster can be trusted to be its
/// description's rendering — what the compose step may do to it.
private enum RasterTrust {
    /// On the rule (put there by the refit or the re-render when it was a
    /// pixel off): the exact ops' pixels ARE the composed description's
    /// rendering at the rule's offset, and a refit may repair a one-pixel
    /// disagreement after the op.
    case onRule
    /// The real face's rendering from another machine — a text family not
    /// installed here (`hasTrustworthyRect` false): the size is not
    /// comparable with the rule, which would measure the fallback face,
    /// but the core's offset stays consistent with the real face's rule,
    /// so the anchor's fraction is carried and nothing is re-fitted.
    case foreignFace
    /// Not this description's rendering at all: the size disagrees with
    /// the rule by more than `DescribedLayer.rasterTolerance` — pixels an
    /// earlier build's Image Size resampled while the description kept its
    /// original size. The pixels stay exactly as the core makes them, the
    /// map composes, and the fraction is reset: the anchor is then whatever
    /// the core's offset implies, as it was before the op. Never
    /// re-rendered, not even by Image Size.
    case stale
}

/// One described layer as the normalization step left it: its index, its
/// resolved description (legacy box materialized), its exact anchor on the
/// canvas BEFORE the op, and how far its raster can be trusted —
/// everything the compose step needs.
private struct CapturedDescription {
    let index: Int
    let description: LayerDescription
    let anchor: CGPoint
    let trust: RasterTrust
}

/// A layer's rect on the canvas (offset and pixel size) — the unit the
/// lossless refit reasons in.
private struct RasterRect: Equatable {
    let x: Int
    let y: Int
    let w: Int
    let h: Int

    var maxX: Int { x + w }
    var maxY: Int { y + h }

    func contains(_ other: RasterRect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }

    var tuple: (x: Int, y: Int, w: Int, h: Int) { (x, y, w, h) }
}

extension RasterDocument {
    /// The core op, then every described layer's description composed with
    /// the op's linear map so it still describes the pixels (normalize →
    /// op → compose, the pipeline at the top of this file): rotate/flip are
    /// meta-only patches — the exact ops already produced the very pixels a
    /// re-render would, at the rule's own offset (a raster the rule sizes
    /// differently, a legacy raster's extra column, is re-fitted by
    /// lossless byte copying); resize re-renders text and shapes through
    /// the scaled map at the scaled anchor with the core's resampled mask
    /// re-cropped and its scaled style kept, and patches the meta of Live
    /// Photos and unrenderable descriptions over the core's resampled
    /// pixels. A STALE raster — one that is not its description's rendering
    /// (`RasterTrust`) — is only ever meta-patched, by every op. nil
    /// exactly when the core op is.
    func applyingDocumentGeometry(_ op: DocumentGeometry) -> RasterDocument? {
        let canvasWidth = width
        let canvasHeight = height
        let (normalized, captured) = normalizingDescribedLayers()
        guard var current = op.perform(on: normalized) else { return nil }
        let map = op.linearMap(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        for layer in captured {
            let composed = layer.description.transform.concatenating(map).snapped()
            let anchor = DescribedLayer.snappedAnchor(
                op.apply(layer.anchor, canvasWidth: canvasWidth, canvasHeight: canvasHeight))
            current = current.composingDescribedLayer(
                layer.index, layer.description, map: composed, anchor: anchor,
                trust: layer.trust, op: op)
        }
        return current
    }

    /// Step 1: every described layer brought onto the render rule at its
    /// own anchor — or classified as one that must be left alone — plus the
    /// list of what was captured (index, resolved description, anchor,
    /// trust) for the compose step. A meta that claims a described kind
    /// but cannot be used (a payload version this build does not decode; a
    /// description whose anchor cannot be recovered: a legacy box under a
    /// non-identity map, which no writer produces, or a source that lays
    /// out to nothing) is dropped, as every paint path drops it: nothing
    /// could locate it to compose honestly, and left in place it would
    /// describe pixels the op is about to move.
    private func normalizingDescribedLayers()
        -> (document: RasterDocument, captured: [CapturedDescription])
    {
        var current = self
        var captured: [CapturedDescription] = []
        for idx in 0..<layerCount {
            guard let description = layerDescription(idx),
                  let anchor = describedAnchor(idx),
                  let info = layerInfo(idx)
            else {
                if LayerDescription.claimedKind(of: layerMeta(idx)) != nil {
                    current = current.withLayerMeta(idx, nil) ?? current
                }
                continue
            }
            var resolved = description.resolved(rasterWidth: info.width)
            var trust: RasterTrust = resolved.hasTrustworthyRect ? .onRule : .foreignFace
            var rerendered = false
            // The size is the one thing the raster can disagree with the
            // rule on: the anchor is derived FROM the offset, so the offset
            // agrees by construction. A disagreement past the tolerance
            // means the raster is not this description's rendering (stale):
            // it is left to the core, and a legacy box read off its
            // resampled width is replaced by the pre-change default. Within
            // it, lossless first: the refit pads or trims transparent
            // margins by byte copying (a legacy raster's extra fraction
            // column), so the exact ops stay byte-lossless; only a
            // disagreement that would cost ink re-renders, and only what may
            // render unprompted — asked last, since a Live Photo's check is
            // a probe decode; a description that cannot keeps its pixels (a
            // documented residual). A text layer whose family is missing is
            // not compared at all: the rule's rect would be the fallback
            // face's (`hasTrustworthyRect`), and a refit onto it would
            // encode that face into the offset.
            if trust == .onRule, let rect = resolved.rasterRect() {
                if !DescribedLayer.rasterAgrees(
                    width: info.width, height: info.height, with: rect)
                {
                    trust = .stale
                    if case let .text(payload) = description, payload.box == .unspecified {
                        let legacyWidth = TextLayer.legacyBoxWidth(
                            canvasWidth: CGFloat(width), anchorX: anchor.x)
                        resolved = .text(payload.resolvingLegacyBox(width: Double(legacyWidth)))
                    }
                } else if info.width != rect.width || info.height != rect.height {
                    if let fitted = current.fittingRasterOntoRule(idx, resolved, anchor: anchor) {
                        current = fitted
                    } else if resolved.isRenderable,
                              let drawn = current.rerenderingDescribedLayer(
                                idx, resolved, anchor: anchor)
                    {
                        current = drawn
                        rerendered = true
                    }
                }
            }
            // A materialized legacy box that was not re-rendered (the
            // raster already is — or was re-fitted onto — the rule's, or is
            // stale) still has to reach the meta before a non-identity map
            // is composed onto it.
            if !rerendered, resolved != description {
                current = current.withLayerMeta(idx, resolved.json()) ?? current
            }
            captured.append(
                CapturedDescription(
                    index: idx, description: resolved, anchor: anchor, trust: trust))
        }
        return (current, captured)
    }

    /// Step 3 for one layer on the document the core op returned: the
    /// description with `map` composed in, placed at `anchor` — meta-only
    /// (plus the lossless refit) for an exact op, re-rendered or
    /// meta-patched for a resize (see the file comment for why each), and
    /// meta-only with the fraction reset for a stale raster whatever the
    /// op. Never fails: a refusal leaves the core's result for that layer
    /// as it is, which is what the op produced anyway.
    private func composingDescribedLayer(
        _ idx: Int, _ description: LayerDescription, map: LinearMap, anchor: CGPoint,
        trust: RasterTrust, op: DocumentGeometry
    ) -> RasterDocument {
        // A map no decoder would accept must not be written: the layer is
        // left as the plain raster the core produced. Only a resize by a
        // factor around 1e-8 — a canvas scaled to a sub-pixel smear — can
        // take an invertible map here; an undecodable meta would degrade
        // the layer to a plain raster on its next read anyway, so clearing
        // it is the same outcome stated plainly.
        guard map.isInvertible else { return withLayerMeta(idx, nil) ?? self }
        let composed = description.withTransform(map)
        // A stale raster: the core's pixels, whatever the op made of them,
        // under the composed map with no fraction — the anchor is whatever
        // the offset implies, as before the op. Never re-rendered (Image
        // Size included: the block would land at a size the user never
        // saw), never re-fitted (the rule's rect is a size these pixels
        // never had).
        if trust == .stale {
            return withLayerMeta(idx, composed.withOriginFraction(.zero).json()) ?? self
        }
        // The description as it will be stored when the raster is on the
        // rule at `anchor`: the anchor's fraction stamped, so the recovery
        // rule (offset − rasterRect.origin + fraction) yields `anchor`.
        let exact = composed.withOriginFraction(DescribedLayer.anchorFraction(anchor))
        if op.isExact {
            // The core's pixels ARE the rendering of `composed` at `anchor`
            // and its offset IS the rule's — a legacy raster the rule sizes
            // differently is re-fitted losslessly first — so only the map
            // and the fraction change; the anchor is recovered from the
            // offset, not asserted. A text layer whose family is missing
            // keeps the core's raster untouched (`foreignFace`): the rule's
            // rect is the fallback face's, and only the core's own offset
            // is consistent with the real face's.
            let fitted = trust == .onRule
                ? fittingRasterOntoRule(idx, exact, anchor: anchor) ?? self : self
            return fitted.withLayerMeta(idx, exact.json()) ?? self
        }
        // Image Size: crisp re-render for text and shapes that may render
        // unprompted; Live Photos and everything else over the core's
        // resample. The re-render reads the mask and style from self — the
        // resized document — so the ones the core scaled are what land.
        if composed.rerendersOnResize,
           let rerendered = rerenderingDescribedLayer(idx, composed, anchor: anchor)
        {
            return rerendered
        }
        // The fallback over the core's resampled pixels: on the rule's rect
        // at P′ when the refit loses nothing (the recovered anchor is then
        // P′ itself), else — or when the rule's rect cannot be trusted, a
        // text family missing here — with the fraction reset: the anchor is
        // then whatever the core's offset implies, and carrying P′'s
        // fraction would only pretend to a precision the resampled pixels
        // lack.
        if trust == .onRule, let fitted = fittingRasterOntoRule(idx, exact, anchor: anchor) {
            return fitted.withLayerMeta(idx, exact.json()) ?? self
        }
        return withLayerMeta(idx, composed.withOriginFraction(.zero).json()) ?? self
    }

    // MARK: - The lossless refit

    /// The document with layer `idx`'s raster on the rule's rect for
    /// `description` at `anchor` (whose fraction `description` must carry):
    /// self when it already is, the raster re-fitted by lossless byte
    /// copying when the rule's rect differs (transparent padding outward, a
    /// crop only through ink-free rows and columns; the mask re-cropped
    /// edge-extending, its enabled flag kept by `setLayerContent`), and nil
    /// when the refit would drop ink, the rect cannot be computed, or the
    /// pixels cannot be read back — the caller then leaves the raster as
    /// the core made it (after the op) or re-renders it (before). The meta
    /// is not written here.
    private func fittingRasterOntoRule(
        _ idx: Int, _ description: LayerDescription, anchor: CGPoint
    ) -> RasterDocument? {
        guard let info = layerInfo(idx), let rect = description.rasterRect(),
              anchor.x.isFinite, anchor.y.isFinite, abs(anchor.x) < 1e9, abs(anchor.y) < 1e9
        else { return nil }
        let from = RasterRect(x: info.offsetX, y: info.offsetY, w: info.width, h: info.height)
        let to = RasterRect(
            x: Int(anchor.x.rounded(.down)) + rect.originX,
            y: Int(anchor.y.rounded(.down)) + rect.originY,
            w: rect.width, h: rect.height)
        if to == from { return self }
        guard let pixels = layerPixels(idx),
              let refitted = Self.refit(pixels, from: from, to: to)
        else { return nil }
        let mask: [UInt8]? = layerHasMask(idx)
            ? layerMaskCoverage(idx).map {
                DescribedLayer.recrop($0, from: from.tuple, to: to.tuple)
            }
            : nil
        return setLayerContent(
            idx, rgba: refitted, width: to.w, height: to.h, offsetX: to.x, offsetY: to.y,
            mask: mask)
    }

    /// `pixels` (straight RGBA8 covering canvas rect `from`) re-fitted into
    /// canvas rect `to` by byte copying: a position outside `from` is
    /// transparent, and a `from` pixel outside `to` may only be dropped when
    /// it is fully transparent — otherwise nil, because the refit would lose
    /// ink. Pure; the mask counterpart is `DescribedLayer.recrop`.
    private static func refit(_ pixels: [UInt8], from: RasterRect, to: RasterRect) -> [UInt8]? {
        guard from.w > 0, from.h > 0, to.w > 0, to.h > 0,
              pixels.count == from.w * from.h * 4
        else { return nil }
        // The overlap, in `from`'s own pixel coordinates (possibly empty).
        let x0 = min(max(to.x - from.x, 0), from.w)
        let x1 = min(max(to.maxX - from.x, 0), from.w)
        let y0 = min(max(to.y - from.y, 0), from.h)
        let y1 = min(max(to.maxY - from.y, 0), from.h)
        // Every source pixel outside the overlap is dropped: it must carry
        // no ink. Pure padding skips the scan.
        if !to.contains(from) {
            for row in 0..<from.h {
                let rowInside = row >= y0 && row < y1
                let rowBase = row * from.w
                for column in 0..<from.w where !(rowInside && column >= x0 && column < x1) {
                    if pixels[(rowBase + column) * 4 + 3] != 0 { return nil }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: to.w * to.h * 4)
        guard x0 < x1, y0 < y1 else { return out }
        let span = (x1 - x0) * 4
        for row in y0..<y1 {
            let sourceStart = (row * from.w + x0) * 4
            let targetStart = ((row + from.y - to.y) * to.w + (x0 + from.x - to.x)) * 4
            out.replaceSubrange(
                targetStart..<(targetStart + span),
                with: pixels[sourceStart..<(sourceStart + span)])
        }
        return out
    }
}
