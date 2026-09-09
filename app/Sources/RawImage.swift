import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// Camera RAW import — the THIRD platform-decode seam, after ImageIO (HEIC)
// and AVFoundation (Live Photos), and the same shape as both: the platform
// turns a file the Rust core has no decoder for into pixels, a colour space
// and a resolution, and the core takes it from there through
// `rz_image_from_rgba`. Nothing in the core knows what a mosaic is.
//
// What makes RAW different from the other two is that the decode is a
// DECISION, not a lookup: the same file develops into a thousand different
// pictures, so the settings are chosen before the pixels land
// (RawDevelopWindowController) and remembered on the document so Revert can
// reproduce them. A RAW is developed ONCE, at open; there is no re-develop
// and no RAW layer kind.

/// A camera RAW file could not be developed. Always names the file, because
/// this error surfaces in a document-open alert where nothing else does.
struct RawImportError: LocalizedError {
    let url: URL
    let reason: String

    var errorDescription: String? {
        "Could not develop \(url.lastPathComponent): \(reason)."
    }
}

/// What one RAW file's own decoder says it can do, plus the values it
/// reports before anything is changed — the "as shot" development.
///
/// The `…Supported` flags do NOT guard the setters: writing
/// `localToneMapAmount` on a file that does not support it succeeds, reads
/// back, and changes no pixels. So support is always READ from these flags
/// and never inferred from a successful write.
struct RawCapabilities: Equatable {
    let lensCorrection: Bool
    let luminanceNoise: Bool
    let colorNoise: Bool
    let sharpness: Bool
    let contrast: Bool
    let detail: Bool
    /// macOS 26+ only. False below it whatever the file carries, since the
    /// property cannot be read at all — which is why the dialog HIDES that
    /// row below 26 rather than disabling it.
    let highlightRecovery: Bool

    /// Every knob's value as the filter itself reports it for this file,
    /// before a single write. Never a hardcoded number: the header says the
    /// amounts "will vary per image", and they measurably do (a synthetic
    /// DNG reports colour noise 0.5, sharpness 0.5, shadow boost 0.9).
    /// Reset restores exactly these.
    let defaults: RawDevelopValues

    fileprivate init(_ filter: CIRAWFilter) {
        lensCorrection = filter.isLensCorrectionSupported
        luminanceNoise = filter.isLuminanceNoiseReductionSupported
        colorNoise = filter.isColorNoiseReductionSupported
        sharpness = filter.isSharpnessSupported
        contrast = filter.isContrastSupported
        detail = filter.isDetailSupported
        // macOS 26+ only; gated because the deployment floor is 15.
        var recoverySupported = false
        var recoveryEnabled = false
        if #available(macOS 26.0, *) {
            recoverySupported = filter.isHighlightRecoverySupported
            recoveryEnabled = filter.isHighlightRecoveryEnabled
        }
        highlightRecovery = recoverySupported
        defaults = RawDevelopValues(
            exposure: Double(filter.exposure),
            customWhiteBalance: false,
            temperature: Double(filter.neutralTemperature),
            tint: Double(filter.neutralTint),
            toneCurve: Double(filter.boostAmount),
            shadows: Double(filter.boostShadowAmount),
            contrast: Double(filter.contrastAmount),
            sharpness: Double(filter.sharpnessAmount),
            detail: Double(filter.detailAmount),
            luminanceNoise: Double(filter.luminanceNoiseReductionAmount),
            colorNoise: Double(filter.colorNoiseReductionAmount),
            lensCorrection: filter.isLensCorrectionEnabled,
            highlightRecovery: recoveryEnabled)
    }

    /// The sparse request made dense against this file: anything the caller
    /// asked for, clamped into its range; anything else, the file's own
    /// value verbatim.
    ///
    /// The file's own values are deliberately NOT clamped. A decoder that
    /// reports a default outside this build's slider range still gets to
    /// keep it, because "as shot" has to mean untouched — and it does mean
    /// exactly that, since the decode writes only the fields that differ
    /// from these.
    func resolve(_ settings: RawDevelopSettings) -> RawDevelopValues {
        var values = defaults
        if let exposure = settings.exposure {
            values.exposure = RawDevelopRange.exposure.clamping(
                exposure, fallback: defaults.exposure)
        }
        // Either half of the pair turns the white balance Custom; the other
        // half then comes from the file (CIRAWFilter derives chromaticity
        // from temperature and tint together).
        if settings.temperature != nil || settings.tint != nil {
            values.customWhiteBalance = true
            if let temperature = settings.temperature {
                values.temperature = RawDevelopRange.temperature.clamping(
                    temperature, fallback: defaults.temperature)
            }
            if let tint = settings.tint {
                values.tint = RawDevelopRange.tint.clamping(tint, fallback: defaults.tint)
            }
        }
        if let toneCurve = settings.toneCurve {
            values.toneCurve = RawDevelopRange.toneCurve.clamping(
                toneCurve, fallback: defaults.toneCurve)
        }
        if let shadows = settings.shadows {
            values.shadows = RawDevelopRange.shadows.clamping(
                shadows, fallback: defaults.shadows)
        }
        if let contrast = settings.contrast {
            values.contrast = RawDevelopRange.contrast.clamping(
                contrast, fallback: defaults.contrast)
        }
        if let sharpness = settings.sharpness {
            values.sharpness = RawDevelopRange.sharpness.clamping(
                sharpness, fallback: defaults.sharpness)
        }
        if let detail = settings.detail {
            values.detail = RawDevelopRange.detail.clamping(detail, fallback: defaults.detail)
        }
        if let luminanceNoise = settings.luminanceNoise {
            values.luminanceNoise = RawDevelopRange.luminanceNoise.clamping(
                luminanceNoise, fallback: defaults.luminanceNoise)
        }
        if let colorNoise = settings.colorNoise {
            values.colorNoise = RawDevelopRange.colorNoise.clamping(
                colorNoise, fallback: defaults.colorNoise)
        }
        if let lensCorrection = settings.lensCorrection {
            values.lensCorrection = lensCorrection
        }
        if let highlightRecovery = settings.highlightRecovery {
            values.highlightRecovery = highlightRecovery
        }
        return values
    }

    /// The display names of the controls THIS file does not support, in the
    /// dialog's own top-to-bottom order, for the card's footnote. The
    /// macOS-26 highlight row is absent from the list below 26 because it is
    /// hidden there — a control that can never come alive on this OS is not
    /// something the file failed to support.
    var unsupportedLabels: [String] {
        var labels: [String] = []
        if !contrast { labels.append("Local contrast") }
        if !sharpness { labels.append("Sharpness") }
        if !detail { labels.append("Detail") }
        if !luminanceNoise { labels.append("Luminance noise") }
        if !colorNoise { labels.append("Colour noise") }
        if !lensCorrection { labels.append("Lens correction") }
        if #available(macOS 26.0, *), !highlightRecovery { labels.append("Highlight recovery") }
        return labels
    }
}

/// A file that really is a camera RAW, and everything the Develop dialog
/// needs to open without decoding it again.
struct RawProbe {
    let url: URL
    /// The size the developed picture will actually be — the output EXTENT,
    /// so a quarter-turned file reports its upright dimensions. `nativeSize`
    /// is deliberately not kept: it is the unrotated sensor size, it is used
    /// for exactly one thing (the preview scale, computed inside
    /// `configured`), and carrying it here would invite sizing a buffer from
    /// it (see `develop`).
    let pixelSize: CGSize
    /// "Canon EOS R5" or nil — the dialog's subtitle, so the user can see
    /// which file they are developing when three are queued behind it.
    let cameraModel: String?
    let capabilities: RawCapabilities
}

/// The result of a full-size develop: straight RGBA8 (row 0 = top), the ICC
/// bytes those numbers belong to, and the resolution the file states.
struct RawDecode {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let profile: Data?
    let dpi: (Double, Double)?
}

enum RawImage {
    /// One CIContext for the whole app (the `PerspectivePreview.swift:15`
    /// precedent). Creating one is the expensive part — the first render
    /// anywhere in the process pays ~98 ms of GPU warm-up, and every render
    /// after it a few milliseconds — and CIContext is documented thread-safe,
    /// so the Develop window's background preview and the main-thread commit
    /// share this one.
    private static let ciContext = CIContext()

    /// The longest side a PREVIEW is decoded to. The preview view is
    /// 516 × 340 pt, so 1600 px is comfortably crisp on a Retina display
    /// while costing about a tenth of a full-size develop (measured on a
    /// 12 MP fixture: 13.4 ms at full size, 1.6 ms at quarter scale).
    private static let previewMaxSide: CGFloat = 1600

    // MARK: - Detection

    /// True when `url` is a camera RAW by TYPE — the positive test the open
    /// ladder branches on.
    ///
    /// It cannot ride the existing decode-failure `catch` the way HEIC does:
    /// DNG, CR2, NEF, ARW, ORF, RW2, PEF and SRW are all TIFF-magic files,
    /// so the core's decoder either errors on an unsupported compression
    /// (and we would platform-decode with Apple's default develop, silently,
    /// with no chance to show the dialog) or SUCCEEDS on an uncompressed IFD
    /// and presents a CFA mosaic as the photograph. Both are silent.
    ///
    /// `public.camera-raw-image` is one umbrella: CR3, CR2, NEF, NRW, ARW,
    /// DNG (Apple ProRAW included), ORF, RW2, RAF, SRW and PEF all conform
    /// to it, and `public.tiff` does not — so a plain TIFF keeps its own
    /// core decode path. The contentType-or-extension expression is the one
    /// `FileDropView.readableImageURLs` already uses.
    static func isRawFile(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .rawImage) ?? false
    }

    /// `url` opened far enough to know it really is a RAW and to describe
    /// its develop controls, or nil when Core Image cannot make a picture
    /// out of it.
    ///
    /// The initialiser is NOT the test: `CIRAWFilter(imageURL:)` never
    /// returns nil — measured, not for a JPEG, a text file, a zero-byte
    /// file, a directory or a path that does not exist. A non-RAW reports
    /// exactly one supported decoder version, `CIRAWDecoderVersionNone`, and
    /// a broken one hands back either no image or an (inf, inf, 0, 0)
    /// extent, so all three are checked.
    ///
    /// A nil here is deliberately NOT an error: the caller falls through to
    /// the ordinary open ladder, which may still read the file, and whose
    /// own error names it if nothing can.
    static func inspect(url: URL) -> RawProbe? {
        guard let filter = CIRAWFilter(imageURL: url),
              filter.supportedDecoderVersions.contains(where: { $0 != .none }),
              let output = filter.outputImage
        else { return nil }
        let extent = output.extent
        guard !extent.isNull, !extent.isInfinite, !extent.isEmpty,
              extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1,
              filter.nativeSize.width >= 1, filter.nativeSize.height >= 1
        else { return nil }
        return RawProbe(
            url: url, pixelSize: extent.integral.size,
            cameraModel: cameraModel(filter.properties),
            capabilities: RawCapabilities(filter))
    }

    // MARK: - Developing

    /// Why a picture of this size cannot be opened by this build, or nil
    /// when it fits.
    ///
    /// **One statement of the limit, asked twice.** `ImageDocument.openRaw`
    /// asks BEFORE it builds the Develop dialog, because the number is
    /// already in `RawProbe.pixelSize` and a file that can never be opened
    /// must not cost the user a whole develop session first — a Fujifilm
    /// GFX100 II frame is 11648 × 8736 = 101.7 MP and a Phase One IQ4 is
    /// 151 MP, both past the cap, and the dialog would have printed those
    /// dimensions in its own subtitle before throwing them away. `develop`
    /// asks again on the extent it is about to allocate a buffer for, which
    /// is the belt-and-braces check the headless path and any later caller
    /// get for free.
    ///
    /// The comparison is in Double BEFORE anything becomes an Int:
    /// `Int(_: Double)` traps on an out-of-range value, and a degenerate
    /// extent is exactly where one would come from.
    static func oversizeReason(_ size: CGSize) -> String? {
        guard size.width * size.height > Double(RasterImage.maxResizePixels) else { return nil }
        return String(
            format: "it is %.0f × %.0f pixels, past this build's ", size.width, size.height)
            + "\(RasterImage.maxResizePixels / 1_000_000) megapixel limit"
    }

    /// Develops `url` at full size with `values` and hands back straight
    /// RGBA8 plus the colour and resolution the document should carry.
    /// Throws — naming the file — for every way the develop can fail, so a
    /// RAW Core Image refuses reports a reason instead of crashing or
    /// silently importing a mosaic.
    static func develop(
        url: URL, values: RawDevelopValues, capabilities: RawCapabilities
    ) throws -> RawDecode {
        guard let filter = configured(
            url: url, values: values, capabilities: capabilities, scale: 1)
        else { throw RawImportError(url: url, reason: "Core Image could not open it") }
        guard let output = filter.outputImage else {
            throw RawImportError(url: url, reason: "Core Image returned no image for it")
        }
        // EVERY size comes from the EXTENT, never from `nativeSize`:
        // measured, a file whose orientation is .right keeps nativeSize
        // (4000, 3000) while the extent becomes (0, 0, 3000, 4000) — the
        // header says nativeSize "is not affected by changing orientation" —
        // so a buffer sized from it is transposed and the picture garbled,
        // and a megapixel guard computed from it answers about a different
        // picture. `.integral` is defensive: CIRAWFilter was measured to
        // round the extent itself even at a fractional scale, but the
        // contract for `bounds:` is an integral rect and the call is free.
        let rect = output.extent.integral
        guard !rect.isNull, !rect.isInfinite, !rect.isEmpty,
              rect.width.isFinite, rect.height.isFinite, rect.width >= 1, rect.height >= 1
        else { throw RawImportError(url: url, reason: "it decoded to an empty image") }
        // The same guard `openRaw` already applied to the probe, asked again
        // on the extent this render is about to allocate for (see
        // `oversizeReason`).
        if let reason = oversizeReason(rect.size) {
            throw RawImportError(url: url, reason: reason)
        }
        let width = Int(rect.width)
        let height = Int(rect.height)
        // Render into the decode's OWN space, converting nothing, and label
        // the document with that same space's ICC bytes. Never assume sRGB:
        // measured, a DNG decoded to Display P3. The rule deciding whether
        // that space may be used — RGB, three components, a 1 × 1 probe
        // context, re-embeddable ICC bytes — is `Bitmap`'s, because it is
        // the same rule the HEIC path applies and it has exactly one home
        // (app/CLAUDE.md names Bitmap.swift as the CoreGraphics⇄core seam).
        // The probe earns its place on THIS path in particular: a
        // decoder-chosen RAW output space still reports RGB, three
        // components and ICC data, so a weaker test would let an
        // extended-range space through and `render(format: .RGBA8,
        // colorSpace:)` would clip or garble the very numbers the document
        // is about to be labelled with.
        let ingest = Bitmap.ingestSpace(of: output.colorSpace)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            // rowBytes is exactly w * 4 (the core wants a tightly packed
            // buffer) and `bounds` is the extent itself, which is not
            // clipped for us: a rect sticking out past it fills the outside
            // with zeroes. Row 0 of the result is the TOP row, as everywhere
            // else, so nothing is flipped.
            ciContext.render(
                output, toBitmap: base, rowBytes: width * 4, bounds: rect,
                format: CIFormat.RGBA8, colorSpace: ingest.space)
        }
        // Core Image renders PREMULTIPLIED (50 %-alpha red comes back as
        // (127, 0, 0, 128)); layer pixels cross the FFI straight. Every
        // alpha byte is 255 on a RAW decode, so this pass short-circuits per
        // pixel and changes nothing — it is called rather than asserted,
        // because the alpha info of a CIContext render depends on the image.
        Bitmap.unpremultiply(&pixels)
        return RawDecode(
            pixels: pixels, width: width, height: height, profile: ingest.profile,
            dpi: statedDPI(url: url, filter: filter))
    }

    /// A small, fast develop for the dialog's live preview: the same
    /// settings, decoded at `previewMaxSide` with draft mode on.
    ///
    /// Built to be called on `PreviewRenderer`'s queue, so it takes VALUES
    /// only and constructs its own filter there — the Develop window owns no
    /// filter at all, and nothing is reachable from two threads. nil rather
    /// than a throw: a preview that cannot be made shows nothing, and the
    /// same failure is reported properly when Open commits.
    ///
    /// `space` is the COLOUR WORKING SPACE, read on the main thread by the
    /// window and passed down (nothing here may touch `ColorSettings`), and
    /// it is what the preview is rendered into rather than the decode's own
    /// space. The commit renders into the decode's space and labels the
    /// document with it, and then `ImageDocument.read` runs
    /// `adoptWorkingSpace()`, which CONVERTS those pixels into the working
    /// space — measured: a DNG decoding to Display P3 lands as sRGB with
    /// `on_open: "converted"`. So a preview in the decode's own space graded
    /// a full-gamut render of a picture that arrives gamut-clipped: the
    /// exposure and white balance a user judged on saturated foliage or a
    /// sunset were judged on colours the document could not hold. Rendering
    /// through the same adoption puts the dialog and the document in one
    /// space, which is the only way the preview can be a preview.
    static func previewImage(
        url: URL, values: RawDevelopValues, capabilities: RawCapabilities,
        space: CGColorSpace
    ) -> CGImage? {
        guard let filter = configured(
                url: url, values: values, capabilities: capabilities, scale: nil),
              let output = filter.outputImage
        else { return nil }
        let rect = output.extent.integral
        guard !rect.isNull, !rect.isInfinite, !rect.isEmpty,
              rect.width >= 1, rect.height >= 1
        else { return nil }
        return ciContext.createCGImage(
            output, from: rect, format: CIFormat.RGBA8, colorSpace: space)
    }

    /// A filter on `url` carrying `values`, at `scale` — or, for `nil`, at
    /// the preview scale computed from this file's own native size, which is
    /// the ONE thing `nativeSize` is used for anywhere in this file.
    private static func configured(
        url: URL, values: RawDevelopValues, capabilities: RawCapabilities, scale: Double?
    ) -> CIRAWFilter? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let requested = scale ?? Double(
            min(1, previewMaxSide / max(filter.nativeSize.width, filter.nativeSize.height, 1)))
        // The newest decoder this file's type supports — the documented
        // default, made explicit. Never a named version literal:
        // CIRAWDecoderVersion.version9 compiles at the macOS 15 target but
        // does not exist on macOS 15, so naming it is a latent runtime
        // hazard on the deployment floor. The header guarantees the array is
        // sorted in increasingly newer order.
        if let newest = filter.supportedDecoderVersions.last { filter.decoderVersion = newest }
        apply(values, defaults: capabilities.defaults, to: filter)
        // scaleFactor is the only knob that changes the output SIZE. A write
        // above 1 clamps itself; a write of 0 does NOT — it yields an
        // (inf, inf, 0, 0) extent — so the lower clamp is ours. Draft mode
        // is for the preview only: it trades quality for decode speed, and
        // the commit must not.
        let safe = requested.isFinite && requested > 0 ? Swift.min(requested, 1) : 1
        filter.scaleFactor = Float(safe)
        filter.isDraftModeEnabled = safe < 1
        return filter
    }

    /// Writes ONLY the knobs that differ from the file's own values.
    ///
    /// That is what makes "as shot" mean untouched rather than "written back
    /// with the number we read", and it is why an unsupported control needs
    /// no guard here: `resolve` leaves it at the file's value, so nothing is
    /// written. A caller who insists on a value the file does not support
    /// gets the framework's own behaviour — the write succeeds and changes
    /// no pixels.
    ///
    /// Deliberately NOT written, each for a reason:
    /// `neutralLocation` (the eyedropper white balance) is write-only, is
    /// silently ignored whenever scaleFactor != 1, has a bottom-left origin
    /// and an 8 px dead border — and there is no canvas to click on before
    /// the document exists; `linearSpaceFilter` raises an uncaught
    /// NSUnknownKeyException from a LATER outputImage read when the filter
    /// has no inputImage key, which terminates the process and Swift cannot
    /// catch; `extendedDynamicRangeAmount` is real but invisible in an 8-bit
    /// pipeline; `orientation` is left at the filter's own EXIF-derived
    /// value, so the camera rotation bakes in exactly as on every other open
    /// path; `isGamutMappingEnabled` keeps its default;
    /// `localToneMapAmount` measured unsupported on every fixture available
    /// (`isLocalToneMapSupported` false), and a slider that cannot be tested
    /// is noise. `moireReductionAmount` is the one omission that is a SCOPE
    /// decision rather than a measurement: `isMoireReductionSupported` is
    /// true on all three synthetic DNG fixtures and writing the amount does
    /// move pixels there, so it could be exposed as an eleventh knob gated
    /// on that flag — it is simply not in the control set this feature
    /// promised, and nothing here should be read as saying it was found
    /// untestable.
    private static func apply(
        _ values: RawDevelopValues, defaults: RawDevelopValues, to filter: CIRAWFilter
    ) {
        if values.exposure != defaults.exposure { filter.exposure = Float(values.exposure) }
        if values.customWhiteBalance {
            // Temperature and tint are one coupled control: writing either
            // re-derives neutralChromaticity from the PAIR, so Custom writes
            // both and As Shot writes neither.
            filter.neutralTemperature = Float(values.temperature)
            filter.neutralTint = Float(values.tint)
        }
        if values.toneCurve != defaults.toneCurve {
            filter.boostAmount = Float(values.toneCurve)
        }
        if values.shadows != defaults.shadows {
            filter.boostShadowAmount = Float(values.shadows)
        }
        if values.contrast != defaults.contrast {
            filter.contrastAmount = Float(values.contrast)
        }
        if values.sharpness != defaults.sharpness {
            filter.sharpnessAmount = Float(values.sharpness)
        }
        if values.detail != defaults.detail { filter.detailAmount = Float(values.detail) }
        if values.luminanceNoise != defaults.luminanceNoise {
            filter.luminanceNoiseReductionAmount = Float(values.luminanceNoise)
        }
        if values.colorNoise != defaults.colorNoise {
            filter.colorNoiseReductionAmount = Float(values.colorNoise)
        }
        if values.lensCorrection != defaults.lensCorrection {
            filter.isLensCorrectionEnabled = values.lensCorrection
        }
        // macOS 26+ only; gated because the deployment floor is 15.
        if #available(macOS 26.0, *), values.highlightRecovery != defaults.highlightRecovery {
            filter.isHighlightRecoveryEnabled = values.highlightRecovery
        }
    }

    // MARK: - Colour, resolution, identity

    /// The print resolution the file states, in ppi per axis, or nil when it
    /// states none — in which case the caller keeps the document's default
    /// rather than inventing one.
    ///
    /// `Bitmap.imageDPI` first, which is the same question every other open
    /// path asks (`kCGImagePropertyDPIWidth/Height`, transposed for a
    /// quarter-turned file). RAW files often do not surface those keys, so
    /// there is a second look at the TIFF resolution tags the file carries —
    /// which are the same tags EXIF means by "resolution", ImageIO reporting
    /// them in the `{TIFF}` dictionary. `{Exif}`'s own
    /// `FocalPlaneXResolution` is deliberately NOT consulted: it describes
    /// the sensor, not the page, and reporting it as ppi would state a
    /// resolution the file never claimed.
    ///
    /// Measured honestly: neither synthetic DNG available here surfaces
    /// `DPIWidth` or a `{TIFF}` `XResolution`, so on those files the
    /// observed behaviour is "keep the default" and the second look is
    /// verified by reading only.
    private static func statedDPI(url: URL, filter: CIRAWFilter) -> (Double, Double)? {
        if let stated = Bitmap.imageDPI(url) { return stated }
        // The filter's own orientation is the one baked into these pixels,
        // and it is already in hand — the same rule `Bitmap.quarterTurned`
        // applies to an ImageIO property dictionary: a 300 × 150 ppi frame
        // stored sideways is a 150 × 300 ppi picture.
        let turned = (5...8).contains(filter.orientation.rawValue)
        return rawDPI(filter.properties, quarterTurned: turned)
    }

    /// The `{TIFF}` resolution tags as a ppi pair, or nil. Internal so the
    /// rule is testable and readable on its own.
    static func rawDPI(
        _ properties: [AnyHashable: Any], quarterTurned: Bool
    ) -> (Double, Double)? {
        guard let tiff = properties[kCGImagePropertyTIFFDictionary as String]
                as? [AnyHashable: Any],
              let x = tiff[kCGImagePropertyTIFFXResolution as String] as? NSNumber,
              let y = tiff[kCGImagePropertyTIFFYResolution as String] as? NSNumber
        else { return nil }
        // ResolutionUnit: 2 = inch, 3 = centimetre, 1 = none. "None" means
        // the pair is an aspect ratio and not a density at all, so it states
        // no resolution; a missing unit is the TIFF default, inch.
        let unit = (tiff[kCGImagePropertyTIFFResolutionUnit as String] as? NSNumber)?.intValue ?? 2
        guard unit == 2 || unit == 3 else { return nil }
        let perInch = unit == 3 ? 2.54 : 1.0
        let (dx, dy) = (x.doubleValue * perInch, y.doubleValue * perInch)
        guard dx.isFinite, dy.isFinite, dx > 0, dy > 0 else { return nil }
        return quarterTurned ? (dy, dx) : (dx, dy)
    }

    /// The camera that made the file, for the dialog's subtitle.
    private static func cameraModel(_ properties: [AnyHashable: Any]) -> String? {
        guard let tiff = properties[kCGImagePropertyTIFFDictionary as String]
                as? [AnyHashable: Any]
        else { return nil }
        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        // Most cameras already repeat the make inside the model ("Canon EOS
        // R5"), so joining unconditionally would stutter.
        let name = model.hasPrefix(make) || make.isEmpty ? model : "\(make) \(model)"
        return name.isEmpty ? nil : name
    }
}

extension RasterDocument {
    /// A single-layer document holding a developed RAW: the pixels, the
    /// profile the decode produced and the resolution the file states.
    ///
    /// A developed RAW is a flat photograph like a JPEG, so its one layer
    /// carries the same "Background" name every other flat open produces —
    /// the caller states it rather than this function deciding. The three
    /// `if let` steps are the core's purity idiom, not carelessness: a
    /// rename to the name the layer already has, a profile the document
    /// already carries and a resolution it already has all answer nil,
    /// which here means "already correct".
    static func from(raw decode: RawDecode, name: String) -> RasterDocument? {
        guard let image = RasterImage.from(
                rgba: decode.pixels, width: decode.width, height: decode.height),
              let built = RasterDocument.from(image: image)
        else { return nil }
        var doc = built.withLayerName(0, name) ?? built
        if let profile = decode.profile, let tagged = doc.assigningProfile(profile) {
            doc = tagged
        }
        if let dpi = decode.dpi, let sized = doc.settingResolution(x: dpi.0, y: dpi.1) {
            doc = sized
        }
        return doc
    }
}
