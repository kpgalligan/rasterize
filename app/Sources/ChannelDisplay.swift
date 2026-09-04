import AppKit

/// What the canvas draws UNDER the rubylith washes — the thing the eye
/// column is really choosing between. Derived from `ChannelVisibility`, so
/// every eye state has exactly one honest answer here and the icons can
/// never contradict the picture.
enum ChannelBase: Equatable {
    /// The colour picture (the RGB row's eye on): the canvas draws its own
    /// projection and the channel display supplies washes only.
    case composite
    /// One colour plane of the composite, in grayscale.
    case plane(RasterPlane)
    /// One alpha channel, in grayscale — "the channel's eye alone is on".
    case channel(Int)
    /// The active layer's mask, in grayscale.
    case layerMask
    /// Every eye is off: the canvas shows its checkerboard and nothing else.
    case nothing

    /// The paint target whose own coverage this base draws — nil for the
    /// colour picture and for nothing at all, which show no coverage.
    ///
    /// A `.plane` base draws the COMPOSITE's plane while the same target
    /// EDITS the active layer's (the display-vs-edit split this feature
    /// carries throughout); for deciding whether a stroke's coverage is on
    /// screen that is the same answer.
    var coverageTarget: PaintTarget? {
        switch self {
        case .composite, .nothing: return nil
        case .plane(let plane): return .plane(plane)
        case .channel(let index): return .channel(index)
        case .layerMask: return .mask
        }
    }
}

/// Which of the Channels panel's rows are "visible" — the eye column. Pure
/// view state, owned by ChannelsPanelViewController and pushed to the
/// editor, which turns it into a `ChannelDisplay`.
///
/// The RGB eye and the three colour-plane eyes are one control between
/// them: with RGB on you are looking at the picture (all three plane eyes
/// read as on); turning a single plane's eye on turns RGB off and shows
/// that plane in grayscale, which is what `plane` records.
struct ChannelVisibility: Equatable {
    /// The RGB row's eye.
    var rgb = true
    /// The ONE colour plane shown while `rgb` is off.
    var plane: RasterPlane?
    /// The layer-mask row's eye.
    var mask = false
    /// Alpha channel rows whose eye is on, by channel index.
    var channels: Set<Int> = []

    /// True when a single colour plane is what the canvas should draw.
    var showsPlaneBase: Bool { !rgb && plane != nil }

    /// What the canvas draws under the washes, in priority order: the colour
    /// composite, the one colour plane chosen, otherwise the LOWEST-numbered
    /// visible channel, otherwise the layer mask, otherwise nothing.
    ///
    /// The two fallbacks are what make the eye column honest. Turning RGB off
    /// with a channel's eye on is Photoshop's "look at this channel in
    /// grayscale"; turning RGB off with nothing else on genuinely hides the
    /// picture, instead of drawing a full-colour composite under four eyes
    /// that all read as closed.
    var base: ChannelBase {
        if rgb { return .composite }
        if let plane = plane { return .plane(plane) }
        if let first = channels.min() { return .channel(first) }
        if mask { return .layerMask }
        return .nothing
    }

    /// The RGB row's eye going on clears any single-plane view.
    mutating func setRGBVisible(_ visible: Bool) {
        rgb = visible
        if visible { plane = nil }
    }

    /// A colour plane's eye: turning it on takes the canvas off the colour
    /// composite and onto that plane; turning off the one that is showing
    /// puts RGB back (there is always something to look at).
    mutating func togglePlane(_ target: RasterPlane) {
        if !rgb, plane == target {
            setRGBVisible(true)
            return
        }
        showPlane(target)
    }

    /// That plane, shown: the half of `togglePlane` that never turns
    /// anything off. Selecting a colour plane's ROW uses this — the canvas
    /// must end up showing what the row names, whatever it was showing
    /// before.
    mutating func showPlane(_ target: RasterPlane) {
        rgb = false
        plane = target
    }

    /// Whether a row's eye draws as on.
    func isVisible(_ row: ChannelRow) -> Bool {
        switch row {
        case .composite: return rgb
        // With the colour composite up, all three plane eyes are on: that
        // is exactly what "you can see red" means there.
        case .plane(let p): return rgb || plane == p
        case .layerMask: return mask
        case .alpha(let index): return channels.contains(index)
        }
    }
}

/// What the canvas shows in place of — and on top of — the composite while
/// a colour plane or an alpha channel is being viewed. Pure VIEW state,
/// rebuilt by EditorViewController+Channels on every target, eye or
/// document change; never undoable, never persisted.
///
/// A crop session wins over the WHOLE display, base and washes alike: the
/// straighten preview rotates the real composite, which a plane base would
/// silently swallow and which an axis-aligned wash would sit on top of,
/// showing the channel where it will not land (the commit rotates every
/// channel through the same matrix). `ImageCanvasView.draw` therefore gates
/// both arms on `cropOverlay == nil`, and the display returns when the crop
/// commits or cancels.
struct ChannelDisplay {
    /// Non-nil: draw THIS grayscale plane instead of the projection.
    let base: CGImage?
    /// WHAT `base` is, for identity: the canvas asks whether the coverage a
    /// stroke is painting is already on screen (`shows`).
    let baseKind: ChannelBase
    /// True when the colour composite must NOT be drawn: either `base`
    /// replaces it, or every eye is off and the canvas shows its
    /// checkerboard alone. The canvas asks THIS, not `base != nil`, so an
    /// eye that reads as closed always means a picture that is not there.
    let replacesComposite: Bool
    /// Rubylith washes drawn over whatever the base is (alpha channels and
    /// the layer mask, when their eye is on with RGB still visible).
    let overlays: [Overlay]

    /// One wash. `mask` is the ALPHA SOURCE, already in the polarity the
    /// channel asks for (see `RasterDocument.ChannelInfo`'s
    /// `colorIndicatesSelected`): the builder inverts, the draw code never
    /// does. That keeps one Quick Mask recipe in the app.
    struct Overlay {
        let mask: CGImage
        let color: NSColor
        let alpha: CGFloat
        /// Which target's coverage this wash draws (`.channel(i)` or
        /// `.mask`) — the canvas's half of `ChannelDisplay.shows`.
        let target: PaintTarget
    }

    var isEmpty: Bool { !replacesComposite && overlays.isEmpty }

    /// True when this display already shows `target`'s own coverage — as the
    /// grayscale base, or as one of the washes over the picture.
    ///
    /// A coverage stroke's ghost is drawn in the rubylith's own red, so over
    /// a wash (or over the plane itself) it reads as MORE mask exactly where
    /// the brush is adding coverage. `ImageCanvasView.drawMaskStrokeGhost`
    /// asks this and switches to the coverage the stroke paints — white for
    /// the brush, black for the eraser — wherever the answer is yes.
    func shows(_ target: PaintTarget) -> Bool {
        if baseKind.coverageTarget == target { return true }
        return overlays.contains { $0.target == target }
    }

    /// Draws `preview ?? base`, flipped. `preview` is the canvas's own
    /// `previewImage`: a sheet previewing an op ON this plane pushes its
    /// grayscale result there exactly as it pushes a colour preview
    /// normally, so a plane view never hides a live preview.
    ///
    /// `quality` is the canvas's own `imageInterpolation` — the composite's
    /// rule, applied here because the inherited context quality is `.default`
    /// and a plane image asks to be interpolated (`makeCGImage` sets
    /// `shouldInterpolate`). Without it a colour plane drew smoothed at 800%
    /// while the picture it replaced drew as crisp pixel squares.
    func drawBase(
        in context: CGContext, bounds: CGRect, preview: CGImage?,
        quality: CGInterpolationQuality
    ) {
        guard let image = preview ?? base else { return }
        context.saveGState()
        context.interpolationQuality = quality
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    /// The rubylith: flip the CTM, clip to the wash's alpha source, fill the
    /// colour at its opacity — `ImageCanvasView.drawQuickMaskOverlay`'s
    /// recipe, with the channel's own colour and opacity substituted for
    /// Quick Mask's hard-coded red at 0.5.
    ///
    /// `previewingPlane` is "a sheet is previewing an op on the plane or
    /// channel that IS the edit target". With `replacesComposite` the
    /// preview lands inside `drawBase`, under the washes, exactly where the
    /// committed plane will be — so they stay. Without it the canvas paints
    /// that grayscale preview over the whole frame itself, and washing the
    /// very channel being previewed in its own rubylith would show a grey
    /// picture veiled in red that matches neither the canvas before Apply nor
    /// the one after; the washes stand down for the length of the preview.
    func drawOverlays(in context: CGContext, bounds: CGRect, previewingPlane: Bool) {
        guard !overlays.isEmpty, !previewingPlane || replacesComposite else { return }
        let rect = CGRect(origin: .zero, size: bounds.size)
        for overlay in overlays {
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.clip(to: rect, mask: overlay.mask)
            context.setFillColor(overlay.color.withAlphaComponent(overlay.alpha).cgColor)
            context.fill(rect)
            context.restoreGState()
        }
    }
}
