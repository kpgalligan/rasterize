import AppKit

/// The colour space a document's PIXELS live in: what every CGImage of those
/// pixels is tagged with, what every CGContext whose bytes go BACK to the
/// core is built in, and what a colour sampled FROM those pixels is
/// expressed in.
///
/// Those are TWO roles, and one class of profile forces them apart. A
/// profile is the pixels' tag (`space(for:)`) as long as CoreGraphics can
/// convert OUT of it; it is also the drawing destination
/// (`drawingSpace(for:)`) as long as ColorSync can convert INTO it AND the
/// core can model it — both of which a LUT profile fails, the class the core
/// deliberately keeps on the document. Drawing into one ColorSync refuses
/// silently produces opaque black, and converting into one the core cannot
/// model makes an authored colour mean two things in one document (the core
/// leaves a layer style's colour alone there), so such a document is tagged
/// with its own profile and PAINTED in sRGB. Every other profile answers the
/// same space to both questions.
///
/// A profile that fails the OTHER direction — valid enough for
/// `CGColorSpace(iccData:)` and still carrying no transform to sRGB — is
/// refused as a tag as well (`drawsThrough`), because every document-pixel
/// CGImage would otherwise draw as an empty image.
///
/// Sites that draw COVERAGE (layer masks, alpha channels, selections, the
/// brush's falloff mask), UI chrome, rubyliths and `DS` tokens do NOT come
/// here — a coverage byte is not a colour, and giving it a document profile
/// would make `clip(to:mask:)` convert values that mean "how much", not
/// "which colour".
///
/// The rule the whole app follows, stated once here so nobody has to
/// reconstruct it:
///
/// - A colour that is **authored** — the colour well, the theme, a shape or
///   text default, an MCP `#RRGGBB` argument — is sRGB and CONVERTS into the
///   document's space exactly once, by ColorSync, on its way into a
///   document-space context.
/// - A colour that is **sampled** — the eyedropper, `sample_color`, anything
///   read out of document pixels — is already in the document's space and
///   converts NOWHERE, so a sample→paint round trip is byte-exact.
enum ColorProfile {
    /// The app's sRGB, made once. The explicit choice for a site that is
    /// deliberately NOT in the document's space (a grey plane preview, a
    /// mask thumbnail, the agent's `render`), and the fallback whenever a
    /// profile cannot be turned into a usable space.
    static let sRGB: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// `profile` as a CGColorSpace — the TAG a document's pixels wear:
    /// what every CGImage of them is built with, what the display transform
    /// reads, what an export embeds. Falls back to sRGB for absent, unusable
    /// or non-RGB bytes: a corrupt profile must never fail a redraw, and a
    /// non-RGB space (Gray, CMYK, Lab) would make `CGImage(…)` fail outright
    /// for an RGBA bitmap.
    static func space(for profile: Data?) -> CGColorSpace {
        entry(for: profile)?.cg ?? sRGB
    }

    /// The space to DRAW into for a document tagged with `profile` — every
    /// CGContext whose bytes go back to the core, and every `CGColor` and
    /// `NSColorSpace` conversion that feeds one.
    ///
    /// It is the profile's own space for a matrix/TRC profile ColorSync can
    /// render INTO, and sRGB for the rest. The rest is real, and it is two
    /// separate refusals. An RGB profile with no B2A tag cannot be a
    /// ColorSync destination at all, and CoreGraphics answers a draw into it
    /// with silence and OPAQUE BLACK: brush, Fill, Gradient, text and shapes
    /// all painted black on such a document while the canvas kept showing it
    /// correctly. And an RGB profile the CORE cannot model — the
    /// `RgbUnconvertible` class it deliberately keeps on the document, a LUT
    /// profile Rasterize displays, relabels and re-embeds correctly — is one
    /// the core converts no authored colour into either, so converting here
    /// would make a style colour and a fill of the same hex disagree.
    ///
    /// Falling back to sRGB puts that document in the same "the numbers are
    /// the numbers" mode the app was in before colour management: an
    /// authored `#FF0000` lands as 255, 0, 0 and a sampled pixel round trips
    /// exactly. It is the honest answer, because a space we cannot convert
    /// INTO is one no colour can be converted into — there is no better
    /// number to write.
    static func drawingSpace(for profile: Data?) -> CGColorSpace {
        entry(for: profile)?.drawing ?? sRGB
    }

    /// The drawing space above as an `NSColorSpace`, for the
    /// authored/sampled colour rule (`NSColor.usingColorSpace`). Falls back
    /// to `.sRGB`.
    static func nsSpace(for profile: Data?) -> NSColorSpace {
        entry(for: profile)?.ns ?? .sRGB
    }

    /// The same split for a site whose destination comes from an IMAGE's own
    /// tag rather than from a document (`PerspectivePreview`, which renders
    /// a warp back into the space the layer it warped was tagged with): the
    /// space itself when it can be drawn into, sRGB when it cannot.
    static func drawingSpace(matching space: CGColorSpace?) -> CGColorSpace {
        guard let space = space else { return sRGB }
        return canRender(into: space) ? space : sRGB
    }

    /// True when ColorSync can convert a colour INTO `space`, which is
    /// exactly the question "may this be a rendering destination?" — the
    /// probe costs ~1.6 µs and is the only reliable answer, since a profile
    /// CoreGraphics accepts as a TAG may still have no B2A transform.
    /// `NSColorSpace(cgColorSpace:)` alone does not answer it: it is
    /// non-nil for a LUT profile whose conversions then all fail.
    private static func canRender(into space: CGColorSpace) -> Bool {
        guard let ns = NSColorSpace(cgColorSpace: space) else { return false }
        return NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).usingColorSpace(ns) != nil
    }

    /// True when CoreGraphics can convert OUT of `space` — the OTHER
    /// direction, and the one every document-pixel CGImage depends on: the
    /// canvas, both thumbnail wells, the agent's render, Copy and Print all
    /// draw an image tagged with it into an sRGB context.
    ///
    /// Asking is not paranoia. A profile can be structurally valid enough
    /// that `CGColorSpace(iccData:)` accepts it, reports `.rgb` and reports
    /// three components, and still carry no transform in this direction —
    /// no matrix, no TRC and no A2B — and the draw then produces a fully
    /// TRANSPARENT result with no error anywhere, so the document renders
    /// blank in every one of those places at once. The core refuses the
    /// class of profile that made this happen (`RZ_ICC_NOT_IMAGE_PROFILE`),
    /// but the check that matters is the one CoreGraphics itself answers,
    /// and it costs a single 1x1 draw per distinct profile.
    ///
    /// The probe is white, and white is the point: any usable RGB space maps
    /// it to something bright, while a space with no usable transform gives
    /// back the untouched, zeroed context.
    private static func drawsThrough(_ space: CGColorSpace) -> Bool {
        let source: [UInt8] = [255, 255, 255, 255]
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        // `Data` copies, and the CFData owns the copy, so nothing here has
        // to outlive the call.
        guard let provider = CGDataProvider(data: Data(source) as CFData),
              let image = CGImage(
                width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return false }
        var out: [UInt8] = [0, 0, 0, 0]
        let drawn = out.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: sRGB, bitmapInfo: info)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        // Opaque, and not black: a blank result is the failure this exists
        // to catch, and an opaque-black one would be just as unusable.
        return drawn && out[3] == 255 && (out[0] | out[1] | out[2]) != 0
    }

    /// One profile's three forms, made together so a document's tag, its
    /// drawing space and its NSColorSpace can never come from different
    /// bytes.
    private struct Entry {
        /// What the pixels ARE.
        let cg: CGColorSpace
        /// What is drawn INTO them — `cg`, or sRGB when `cg` cannot be a
        /// destination.
        let drawing: CGColorSpace
        /// `drawing` as an `NSColorSpace`.
        let ns: NSColorSpace
    }

    /// Distinct profiles kept before the cache is emptied. Real use holds a
    /// handful — one per open document plus the two built-ins — so this is
    /// a backstop against a script assigning thousands of distinct
    /// profiles, not a tuning knob. Clearing wholesale rather than evicting
    /// one entry keeps the policy a single line; the refill costs one
    /// `CGColorSpace(iccData:)` per live document.
    private static let maxCachedProfiles = 32

    /// The bytes of the built-in sRGB profile, fetched once. A document
    /// carrying exactly these is the overwhelmingly common case, and it is
    /// the one that must behave EXACTLY as it did before colour management
    /// existed — see `build`.
    private static let builtinSRGBBytes: Data = RasterProfile.builtin(.sRGB)

    /// Guards `cache`. A redraw asks per document change on the main thread
    /// while the sheets ask from `PreviewRenderer`'s background queue, so
    /// both the lookup and the insert have to be serialized.
    private static let lock = NSLock()

    /// Profile bytes → the three forms, `nil` for bytes CoreGraphics
    /// refused. Failures are cached too: a document carrying an unusable
    /// profile would otherwise re-parse it on every frame.
    private static var cache: [Data: Entry?] = [:]

    private static func entry(for profile: Data?) -> Entry? {
        guard let profile = profile, !profile.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[profile] { return hit }
        let made = build(profile)
        if cache.count >= maxCachedProfiles { cache.removeAll(keepingCapacity: true) }
        cache[profile] = made
        return made
    }

    private static func build(_ profile: Data) -> Entry? {
        // Our built-in sRGB IS the platform's sRGB — same primaries, same
        // IEC 61966-2.1 transfer curve — so it resolves to the shared named
        // space rather than to a private one built from the same numbers.
        // That is not an optimization: it makes CFEqual comparisons against
        // `sRGB` answer true, which is what lets the agent render, the
        // overlay contexts and every other "is this already sRGB?" test
        // take their identity path and leave an sRGB document byte-for-byte
        // where it was before colour management existed. (Only the CG/NS
        // tags are normalized; an export still embeds the core's own bytes.)
        if profile == builtinSRGBBytes { return Entry(cg: sRGB, drawing: sRGB, ns: .sRGB) }
        guard let cg = CGColorSpace(iccData: profile as CFData),
              cg.model == .rgb, cg.numberOfComponents == 3,
              // BOTH directions are asked, because they fail separately and
              // the failures look nothing alike. This one — can CoreGraphics
              // convert OUT of it? — decides whether the pixels may wear the
              // profile as their TAG at all: a space that cannot be drawn
              // FROM makes the canvas, the thumbnails, the agent's render,
              // Copy and Print all produce an empty image, silently and
              // everywhere at once. Falling back to no entry puts such a
              // document in "the numbers are the numbers" mode instead,
              // which is wrong only in appearance and is visible.
              drawsThrough(cg)
        else { return nil }
        // The destination question is asked ONCE per profile, here, and
        // cached with it — see `drawingSpace(for:)` for why a space that is
        // a perfectly good tag can still be an impossible destination. When
        // it is, the pixels keep their own tag and everything drawn into
        // them is sRGB.
        //
        // It is asked of the CORE as well as of ColorSync, because the core
        // asks it too and the two answers have to be the same one. A layer
        // style's authored colour converts into the document's space in
        // `style_composite`, and the core skips that conversion exactly when
        // it cannot model the profile — so gating this side on ColorSync
        // alone let a profile ColorSync could render into but the core could
        // not model (Adobe's LUT-based HDR_P3_D65_ST2084, say) convert an
        // authored `#FF0000` here and not there: a fill came out #7D372C and
        // a Color Overlay of the same hex came out #FF0000, in one document,
        // baked in by Merge Down, Flatten and every export.
        guard let ns = NSColorSpace(cgColorSpace: cg), canRender(into: cg),
              RasterProfile.inspect(profile).kind == .rgbMatrix
        else {
            return Entry(cg: cg, drawing: sRGB, ns: .sRGB)
        }
        return Entry(cg: cg, drawing: cg, ns: ns)
    }

    /// A colour as straight-alpha RGBA bytes IN `space` — the one place the
    /// authored/sampled rule above turns an `NSColor` into the numbers the
    /// core stores, for the paths that hand bytes to the core DIRECTLY
    /// instead of drawing through a document-space context.
    ///
    /// Both spellings of Fill, Gradient and Plane Paint call it —
    /// `EditorViewController.colorBytes` for the tools,
    /// `AgentServer.colorRGBA` for their MCP mirrors — because two copies of
    /// this conversion is exactly how they came to disagree: the agent's
    /// copy converted to sRGB, so on a Display P3 document `fill` and
    /// `gradient` painted the literal hex while `brush_stroke` and
    /// `add_shape_layer`, drawing through a document-space context, painted
    /// the converted colour. One implementation, one answer.
    ///
    /// nil only when ColorSync refuses the conversion, which leaves the
    /// caller to refuse rather than paint a made-up colour.
    static func bytes(_ color: NSColor, in space: NSColorSpace) -> [UInt8]? {
        guard let c = color.usingColorSpace(space) else { return nil }
        // Converting INTO a space narrower than the one the colour was
        // authored in can land a component outside 0…1, where the byte
        // conversion would trap (ChannelOptionsSheetController's rule).
        let byte: (CGFloat) -> UInt8 = { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        return [
            byte(c.redComponent), byte(c.greenComponent),
            byte(c.blueComponent), byte(c.alphaComponent),
        ]
    }

    /// A pixel READ out of a document in `space`, spelled as the sRGB bytes
    /// a colour ARGUMENT has to be given to paint that same colour back,
    /// and whether that spelling actually reproduces the pixel.
    ///
    /// The eyedropper needs no such thing: it keeps an `NSColor` that
    /// carries the document's space, so `bytes(_:in:)` converts it nowhere
    /// and the round trip is byte-exact. A hex string over MCP carries no
    /// space, and every colour argument in that surface is AUTHORED, i.e.
    /// sRGB — so `sample_color` reports the pixel's own numbers *and* this,
    /// the spelling that survives the trip back. Identical to the pixel on
    /// an sRGB document, where the conversion is the identity.
    ///
    /// `exact` is false when the pixel is OUTSIDE the sRGB gamut, where no
    /// sRGB hex can name it: P3 (255, 0, 0) spells `#FF0000`, and painting
    /// `#FF0000` back writes P3 (234, 51, 35) — a visibly duller red. The
    /// caller has to say so; a silent clamp is how "sample this and paint it
    /// over there" quietly paints a different colour on exactly the
    /// documents colour management was added for. It is decided by the round
    /// trip rather than by inspecting components, with a one-code tolerance
    /// so that the double quantization an in-gamut colour goes through is
    /// not reported as a gamut problem.
    static func paintBytes(
        _ rgba: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), in space: NSColorSpace
    ) -> (bytes: [UInt8], exact: Bool) {
        let sampled = NSColor(
            colorSpace: space,
            components: [
                CGFloat(rgba.r) / 255, CGFloat(rgba.g) / 255,
                CGFloat(rgba.b) / 255, CGFloat(rgba.a) / 255,
            ],
            count: 4)
        // A colour outside the sRGB gamut clamps to the nearest sRGB one —
        // the same thing `render` does to show the agent the document at
        // all, so the two agree about what it is looking at.
        guard let painted = bytes(sampled, in: .sRGB) else {
            return ([rgba.r, rgba.g, rgba.b, rgba.a], true)
        }
        let back = NSColor(
            colorSpace: .sRGB,
            components: [
                CGFloat(painted[0]) / 255, CGFloat(painted[1]) / 255,
                CGFloat(painted[2]) / 255, CGFloat(painted[3]) / 255,
            ],
            count: 4)
        guard let round = bytes(back, in: space) else { return (painted, true) }
        let source = [rgba.r, rgba.g, rgba.b]
        let exact = zip(source, round).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        return (painted, exact)
    }
}

extension RasterDocument {
    /// The ONE accessor the display, thumbnail, round-trip, ingest and
    /// export sites ask — the TAG the pixels wear. Safe on
    /// `PreviewRenderer`'s queue on the same terms as `flattened()` — one
    /// queue at a time touches a handle.
    var colorSpace: CGColorSpace { ColorProfile.space(for: iccProfile) }

    /// The space every CGContext whose bytes go BACK to this document is
    /// built in. The same space as `colorSpace` for every profile that can
    /// be a rendering destination, and sRGB for the LUT profiles that
    /// cannot — see `ColorProfile.drawingSpace(for:)`.
    var drawingSpace: CGColorSpace { ColorProfile.drawingSpace(for: iccProfile) }

    /// The drawing space as an `NSColorSpace`: what an authored colour
    /// converts INTO and what a sampled colour is already expressed in.
    var nsColorSpace: NSColorSpace { ColorProfile.nsSpace(for: iccProfile) }
}

extension ImageDocument {
    /// Forward, so a site holding the NSDocument need not unwrap `doc`.
    var colorSpace: CGColorSpace { doc?.colorSpace ?? ColorProfile.sRGB }

    /// Forward, for the sites that DRAW into the document.
    var drawingSpace: CGColorSpace { doc?.drawingSpace ?? ColorProfile.sRGB }

    /// Forward, for the authored/sampled colour rule.
    var nsColorSpace: NSColorSpace { doc?.nsColorSpace ?? .sRGB }
}
