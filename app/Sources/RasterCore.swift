import AppKit
import UniformTypeIdentifiers

/// Error thrown by the Rust core, carrying the message from `err_out`.
struct RasterCoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Consumes a Rust-allocated error string and returns its contents.
private func takeErrorMessage(_ err: UnsafeMutablePointer<CChar>?, fallback: String) -> String {
    guard let err = err else { return fallback }
    defer { rz_string_free(err) }
    return String(cString: err)
}

/// Owning Swift wrapper around an `RzImage *` handle from the Rust core.
/// Handles are immutable: every operation returns a new handle.
final class RasterImage {
    let ptr: OpaquePointer

    init(owning pointer: OpaquePointer) {
        self.ptr = pointer
    }

    deinit {
        rz_image_free(ptr)
    }

    static func open(url: URL) throws -> RasterImage {
        var err: UnsafeMutablePointer<CChar>? = nil
        guard let handle = rz_image_open(url.path, &err) else {
            throw RasterCoreError(
                message: takeErrorMessage(err, fallback: "Could not open \(url.lastPathComponent)."))
        }
        return RasterImage(owning: handle)
    }

    /// Wraps an in-memory STRAIGHT-alpha (non-premultiplied) RGBA8 buffer,
    /// row 0 = top, exactly `width * height * 4` bytes — the same convention
    /// as `withLayerPixels(_:rgba:width:height:)`, and the way pixels the
    /// core cannot decode itself (a HEIC still, a Live Photo video frame)
    /// become an image without a round trip through a temporary file. nil for
    /// a bad size or a buffer whose length disagrees with it.
    static func from(rgba pixels: [UInt8], width: Int, height: Int) -> RasterImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              width * height <= maxResizePixels
        else { return nil }
        return pixels.withUnsafeBufferPointer { buffer in
            rz_image_from_rgba(buffer.baseAddress, UInt32(width), UInt32(height))
                .map { RasterImage(owning: $0) }
        }
    }

    var width: Int { Int(rz_image_width(ptr)) }
    var height: Int { Int(rz_image_height(ptr)) }
    var pixelSize: NSSize { NSSize(width: width, height: height) }

    private func wrap(_ result: OpaquePointer?) -> RasterImage? {
        result.map { RasterImage(owning: $0) }
    }

    func rotated90() -> RasterImage? { wrap(rz_image_rotate90(ptr)) }
    func rotated180() -> RasterImage? { wrap(rz_image_rotate180(ptr)) }
    func rotated270() -> RasterImage? { wrap(rz_image_rotate270(ptr)) }
    func flippedH() -> RasterImage? { wrap(rz_image_flip_horizontal(ptr)) }
    func flippedV() -> RasterImage? { wrap(rz_image_flip_vertical(ptr)) }

    func cropped(x: Int, y: Int, w: Int, h: Int) -> RasterImage? {
        guard x >= 0, y >= 0, w > 0, h > 0, x + w <= width, y + h <= height else { return nil }
        return wrap(rz_image_crop(ptr, UInt32(x), UInt32(y), UInt32(w), UInt32(h)))
    }

    /// Upper bound on resize targets, mirroring the core's contract
    /// (`rz_image_resize` returns NULL above w*h = 100,000,000).
    static let maxResizePixels = 100_000_000

    func resized(w: Int, h: Int, filter: RzResizeFilter) -> RasterImage? {
        guard w > 0, h > 0, w * h <= Self.maxResizePixels else { return nil }
        return wrap(rz_image_resize(ptr, UInt32(w), UInt32(h), filter))
    }

    func adjusted(brightness: Double, contrast: Double, saturation: Double) -> RasterImage? {
        wrap(rz_image_adjust(ptr, Float(brightness), Float(contrast), Float(saturation)))
    }

    func grayscaled() -> RasterImage? { wrap(rz_image_grayscale(ptr)) }
    func inverted() -> RasterImage? { wrap(rz_image_invert(ptr)) }
    func sepia() -> RasterImage? { wrap(rz_image_sepia(ptr)) }
    func blurred(sigma: Double) -> RasterImage? { wrap(rz_image_blur(ptr, Float(sigma))) }
    func sharpened(amount: Double) -> RasterImage? { wrap(rz_image_sharpen(ptr, Float(amount))) }
    func clone() -> RasterImage? { wrap(rz_image_clone(ptr)) }

    func hueRotated(degrees: Double) -> RasterImage? {
        wrap(rz_image_hue_rotate(ptr, Float(degrees)))
    }

    func levels(black: Double, white: Double, gamma: Double) -> RasterImage? {
        wrap(rz_image_levels(ptr, Float(black), Float(white), Float(gamma)))
    }

    func thresholded(level: Double) -> RasterImage? {
        wrap(rz_image_threshold(ptr, Float(level)))
    }

    func posterized(levels: Int) -> RasterImage? {
        guard levels >= 2, levels <= 64 else { return nil }
        return wrap(rz_image_posterize(ptr, UInt32(levels)))
    }

    func pixelated(block: Int) -> RasterImage? {
        guard block >= 1, block <= 1024 else { return nil }
        return wrap(rz_image_pixelate(ptr, UInt32(block)))
    }

    func noised(amount: Double, seed: UInt64) -> RasterImage? {
        wrap(rz_image_noise(ptr, Float(amount), seed))
    }

    func edgeDetected() -> RasterImage? { wrap(rz_image_edge_detect(ptr)) }
    func embossed() -> RasterImage? { wrap(rz_image_emboss(ptr)) }

    // MARK: - Adjustments, statistics and auto tone

    /// The adjustment `op` with `params` applied destructively — the SAME
    /// object an adjustment layer's meta carries, run through the SAME core
    /// code the compositor runs (core/src/adjust.rs's schema table is the
    /// contract). One export covers every op, which is what makes the
    /// filter and the layer incapable of drifting.
    ///
    /// nil for an unknown op or parameters the core refuses; the core's
    /// message goes to the log only, because every caller validates against
    /// `AdjustmentSchema` first and a sheet has nowhere to put a second
    /// refusal.
    func applyingAdjustment(op: String, params: [String: Any]) -> RasterImage? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: params, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        var err: UnsafeMutablePointer<CChar>? = nil
        let handle = rz_image_adjust_op(ptr, op, json, &err)
        if handle == nil, err != nil {
            NSLog("rasterize: adjustment %@ refused: %@",
                  op, takeErrorMessage(err, fallback: "invalid parameters"))
        }
        return wrap(handle)
    }

    /// 1024 counts — 256 red, then green, then blue, then Rec. 709 luma —
    /// and the number of pixels counted. A pixel counts when its alpha is
    /// non-zero and, with a mask, its coverage is at least 128. `stride`
    /// counts every stride-th pixel in row-major order (0 and 1 both mean
    /// every pixel) and the total says how many were actually counted, so
    /// proportions stay comparable at any stride.
    ///
    /// Deliberately a flat array plus a count and not a struct: the typed
    /// value lives beside the panel that draws it, so this file stays free
    /// of feature types.
    func histogram(mask: [UInt8]?, stride: Int) -> (bins: [UInt32], total: UInt64)? {
        if let mask = mask, mask.count != width * height { return nil }
        var bins = [UInt32](repeating: 0, count: 1024)
        var total: UInt64 = 0
        let step = UInt32(max(1, min(stride, Int(UInt32.max))))
        let ok = bins.withUnsafeMutableBufferPointer { out -> Bool in
            guard let mask = mask else {
                return rz_image_histogram(ptr, nil, step, out.baseAddress, &total)
            }
            return mask.withUnsafeBufferPointer { coverage in
                rz_image_histogram(ptr, coverage.baseAddress, step, out.baseAddress, &total)
            }
        }
        return ok ? (bins, total) : nil
    }

    /// The straight RGBA at (x, y): the plain mean of the (2*reach+1)
    /// square about it with out-of-bounds pixels dropped (reach 0/1/2 =
    /// point, 3×3, 5×5), truncating. The CENTRE may be outside the image —
    /// nil only when NO pixel of the block is inside, which is exactly what
    /// the eyedropper needs at a canvas edge.
    func sample(x: Int, y: Int, reach: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard reach >= 0, reach <= 2 else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let ok = rgba.withUnsafeMutableBufferPointer { out in
            rz_image_sample(
                ptr, Int32(clamping: x), Int32(clamping: y), UInt32(reach), out.baseAddress)
        }
        return ok ? (rgba[0], rgba[1], rgba[2], rgba[3]) : nil
    }

    /// Levels parameters derived from this image's own histogram — the same
    /// counting rule `histogram` uses, so a transparent surround never pins
    /// the black point at 0. `clip` is the share of counted pixels dropped
    /// at each end (0…0.1; 0.001 is Photoshop's 0.1 %). nil when the result
    /// would change nothing, so the caller registers no undo step.
    func autoLevels(mask: [UInt8]?, mode: RzAutoMode, clip: Double)
        -> (black: [Double], white: [Double], gamma: [Double])?
    {
        if let mask = mask, mask.count != width * height { return nil }
        var params = [Float](repeating: 0, count: 9)
        let ok = params.withUnsafeMutableBufferPointer { out -> Bool in
            guard let mask = mask else {
                return rz_image_auto_levels(ptr, nil, mode, Float(clip), out.baseAddress)
            }
            return mask.withUnsafeBufferPointer { coverage in
                rz_image_auto_levels(
                    ptr, coverage.baseAddress, mode, Float(clip), out.baseAddress)
            }
        }
        guard ok else { return nil }
        let values = params.map(Double.init)
        return (Array(values[0..<3]), Array(values[3..<6]), Array(values[6..<9]))
    }

    /// Levels with a black point, white point and gamma per channel — the
    /// twin `autoLevels`' nine numbers feed. nil unless every channel has
    /// 0 ≤ black < white ≤ 1 and gamma in 0.1…10.
    func levelsChannels(black: [Double], white: [Double], gamma: [Double]) -> RasterImage? {
        guard black.count == 3, white.count == 3, gamma.count == 3 else { return nil }
        let b = black.map(Float.init)
        let w = white.map(Float.init)
        let g = gamma.map(Float.init)
        return b.withUnsafeBufferPointer { bp in
            w.withUnsafeBufferPointer { wp in
                g.withUnsafeBufferPointer { gp in
                    wrap(rz_image_levels_channels(
                        ptr, bp.baseAddress, wp.baseAddress, gp.baseAddress))
                }
            }
        }
    }

    /// Composites a full-frame premultiplied RGBA8 overlay (top row first, no
    /// row padding) onto this image. `data` must point to width*height*4
    /// bytes; the dimensions must match this image exactly.
    func composited(
        premultipliedOverlay data: UnsafePointer<UInt8>,
        width: Int, height: Int,
        mode: RzCompositeMode, alpha: Double
    ) -> RasterImage? {
        guard width == self.width, height == self.height else { return nil }
        return wrap(rz_image_composite(ptr, data, UInt32(width), UInt32(height), mode, Float(alpha)))
    }

    /// Multiplies each pixel's alpha by a full-frame u8 coverage mask (the
    /// selection convention: 0 hides, 255 keeps, intermediate values scale
    /// proportionally). `coverage` must be exactly width*height bytes, row 0
    /// = top — the buffer `CanvasSelection.maskBytes()` produces.
    func masked(by coverage: [UInt8]) -> RasterImage? {
        let (w, h) = (width, height)
        guard coverage.count == w * h else { return nil }
        return coverage.withUnsafeBufferPointer { buffer in
            wrap(rz_image_apply_mask(ptr, buffer.baseAddress, UInt32(w), UInt32(h)))
        }
    }

    func save(to url: URL, format: RzFormat, jpegQuality: Int) throws {
        var err: UnsafeMutablePointer<CChar>? = nil
        let quality = UInt8(min(max(jpegQuality, 1), 100))
        guard rz_image_save(ptr, url.path, format, quality, &err) else {
            throw RasterCoreError(
                message: takeErrorMessage(err, fallback: "Could not save \(url.lastPathComponent)."))
        }
    }

    // The CGImage reads the Rust pixel buffer in place (no copy): the data
    // provider holds a retain on this wrapper, so the buffer outlives the
    // CGImage even if the last Swift reference to the handle goes away. The
    // pixel data behind a handle never changes, so this stays coherent, and
    // deliberately nothing is cached — a strong cache would cycle through the
    // provider's retain, and undo-stack handles would pin full-size CGImages.
    //
    // `space` is the colour space to TAG the pixels with; NOTHING is
    // converted here (the buffer is read in place, and converting would mean
    // a copy per frame). Document pixels pass `doc.colorSpace`; coverage
    // planes, mask thumbnails and deliberately-sRGB exits pass
    // `ColorProfile.sRGB`. There is deliberately no default: a default is
    // exactly the trap that leaves a new call site silently sRGB.
    func makeCGImage(in space: CGColorSpace) -> CGImage? {
        let w = width
        let h = height
        guard w > 0, h > 0, let pixels = rz_image_pixels_rgba(ptr) else { return nil }
        let info = Unmanaged.passRetained(self).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: info,
            data: UnsafeRawPointer(pixels),
            size: w * h * 4,
            releaseData: { info, _, _ in
                Unmanaged<RasterImage>.fromOpaque(info!).release()
            })
        else {
            Unmanaged<RasterImage>.fromOpaque(info).release()
            return nil
        }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent)
    }
}

// MARK: - Composite pixel sampling (eyedropper)

extension RasterImage {
    /// The straight (non-premultiplied) RGBA of one pixel, read in place
    /// from the handle's pixel buffer (row 0 = top, matching the FFI
    /// convention); nil outside the image. The buffer behind a handle never
    /// changes, so this is safe and O(1) — used by the editor's eyedropper
    /// and the agent's sample_color, both against the flattened composite.
    func pixelRGBA(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        let w = width
        guard x >= 0, y >= 0, x < w, y < height,
              let pixels = rz_image_pixels_rgba(ptr)
        else { return nil }
        let offset = (y * w + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    /// Canonical hex form of a sampled pixel: #RRGGBB, with the alpha byte
    /// appended (#RRGGBBAA) only when the pixel is not fully opaque —
    /// matching the color syntax the paint tools accept.
    static func hexString(_ rgba: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> String {
        let base = String(format: "#%02X%02X%02X", rgba.r, rgba.g, rgba.b)
        return rgba.a == 255 ? base : base + String(format: "%02X", rgba.a)
    }
}

extension RzBlendMode {
    /// The full blend-mode set in Photoshop menu order, grouped the way the
    /// Photoshop menu draws its separators. The layers panel builds its popup
    /// from these groups; display titles differ from the C constant names
    /// only where Photoshop does (ADDITION shows as "Linear Dodge (Add)").
    static let blendModeGroups: [[(RzBlendMode, String)]] = [
        [
            (RZ_BLEND_NORMAL, "Normal"),
            (RZ_BLEND_DISSOLVE, "Dissolve"),
        ],
        [
            (RZ_BLEND_DARKEN, "Darken"),
            (RZ_BLEND_MULTIPLY, "Multiply"),
            (RZ_BLEND_COLOR_BURN, "Color Burn"),
            (RZ_BLEND_LINEAR_BURN, "Linear Burn"),
            (RZ_BLEND_DARKER_COLOR, "Darker Color"),
        ],
        [
            (RZ_BLEND_LIGHTEN, "Lighten"),
            (RZ_BLEND_SCREEN, "Screen"),
            (RZ_BLEND_COLOR_DODGE, "Color Dodge"),
            (RZ_BLEND_ADDITION, "Linear Dodge (Add)"),
            (RZ_BLEND_LIGHTER_COLOR, "Lighter Color"),
        ],
        [
            (RZ_BLEND_OVERLAY, "Overlay"),
            (RZ_BLEND_SOFT_LIGHT, "Soft Light"),
            (RZ_BLEND_HARD_LIGHT, "Hard Light"),
            (RZ_BLEND_VIVID_LIGHT, "Vivid Light"),
            (RZ_BLEND_LINEAR_LIGHT, "Linear Light"),
            (RZ_BLEND_PIN_LIGHT, "Pin Light"),
            (RZ_BLEND_HARD_MIX, "Hard Mix"),
        ],
        [
            (RZ_BLEND_DIFFERENCE, "Difference"),
            (RZ_BLEND_EXCLUSION, "Exclusion"),
            (RZ_BLEND_SUBTRACT, "Subtract"),
            (RZ_BLEND_DIVIDE, "Divide"),
        ],
        [
            (RZ_BLEND_HUE, "Hue"),
            (RZ_BLEND_SATURATION, "Saturation"),
            (RZ_BLEND_COLOR, "Color"),
            (RZ_BLEND_LUMINOSITY, "Luminosity"),
        ],
    ]

    /// Flat menu-order list for callers that don't care about grouping.
    /// Deliberately WITHOUT Pass Through: this list feeds the brush, clone
    /// and Apply Image menus and the agent catalog's shared blend vocabulary,
    /// where a group's declaration has no meaning (the inverse of the
    /// gray-degenerate rule below, which subtracts from this list instead).
    static let allBlendModes: [(RzBlendMode, String)] = blendModeGroups.flatMap { $0 }

    /// The vocabulary a GROUP entry offers: Pass Through — Photoshop's
    /// default for a new group, and the mode that lets an adjustment layer
    /// inside the group reach the layers below it — ahead of every ordinary
    /// mode. The layers-panel header popup and `set_layer_properties` use
    /// this when the entry is a group; nothing else does, because the core
    /// refuses Pass Through on a raster layer.
    static let groupBlendModes: [(RzBlendMode, String)] =
        [(RZ_BLEND_PASS_THROUGH, "Pass Through")] + allBlendModes

    /// `groupBlendModes`' names alone, in the same order.
    static let groupBlendNames: [String] = groupBlendModes.map { $0.1 }

    /// The four HSL modes, which carry NO information on a SINGLE 8-bit
    /// plane: the W3C defines them over an RGB triple, and a gray triple has
    /// zero saturation, so Hue, Saturation and Color answer the base verbatim
    /// while Luminosity collapses to Normal. `rz_blend_planes` refuses them
    /// for that reason (see the header's "Channels" section), so anything
    /// offering blend modes for one plane — Calculations, and Apply Image
    /// onto a colour plane or an alpha channel — leaves them out. Three
    /// planes blended as one colour (`RasterPlaneMath.blendRGB`) accept them:
    /// that is the form in which they mean something.
    static let grayDegenerateModes: [RzBlendMode] = [
        RZ_BLEND_HUE, RZ_BLEND_SATURATION, RZ_BLEND_COLOR, RZ_BLEND_LUMINOSITY,
    ]

    /// True for a mode `rz_blend_planes` refuses on one plane.
    static func degeneratesOnGray(_ mode: RzBlendMode) -> Bool {
        grayDegenerateModes.contains { $0 == mode }
    }

    /// Display name for a mode (status bar, layer-row meta lines).
    ///
    /// Pass Through is answered AHEAD of the table lookup: it is absent from
    /// `allBlendModes` on purpose, and the lookup's `?? "Normal"` fallback
    /// would otherwise report a pass-through group as Normal — which is the
    /// one thing it is not, and would make `get_document` contradict the
    /// core.
    static func displayName(for mode: RzBlendMode) -> String {
        if mode == RZ_BLEND_PASS_THROUGH { return "Pass Through" }
        return allBlendModes.first { $0.0 == mode }?.1 ?? "Normal"
    }
}

/// Owning Swift wrapper around an `RzDocument *` handle from the Rust core:
/// a canvas size plus a bottom-first layer stack. Handles are immutable;
/// every operation returns a new handle. Handles share unchanged layer pixel
/// buffers (copy-on-write), so clones and per-layer edits are cheap and the
/// undo stack can keep whole-document snapshots.
final class RasterDocument {
    let ptr: OpaquePointer

    /// `iccProfile`'s memo: the outer optional is "not read yet", the inner
    /// one the read's own answer. Guarded by `iccLock` — a handle is read
    /// from the main thread and from `PreviewRenderer`'s queue, and while
    /// the CORE is happy with that (its ops are pure reads), a Swift
    /// property written from both is a data race.
    private var cachedICCProfile: Data??

    /// Serializes the memo above. One shared lock rather than one per
    /// document: it is held for a pointer copy, and the contended case is
    /// two threads asking about the same document anyway.
    private static let iccLock = NSLock()

    init(owning pointer: OpaquePointer) {
        self.ptr = pointer
    }

    deinit {
        rz_doc_free(ptr)
    }

    static func open(url: URL) throws -> RasterDocument {
        var err: UnsafeMutablePointer<CChar>? = nil
        guard let handle = rz_doc_open(url.path, &err) else {
            throw RasterCoreError(
                message: takeErrorMessage(err, fallback: "Could not open \(url.lastPathComponent)."))
        }
        return RasterDocument(owning: handle)
    }

    /// True when opening `url` would preserve whatever EXIF, XMP and IPTC
    /// the file holds: a JPEG, a PNG or a native `.rz`. False for every
    /// other container — a TIFF, WebP, GIF, BMP or PSD arrives as pixels and
    /// drops its capture data, which such a file really can carry — and for
    /// a file that cannot be read.
    static func metadataWalked(at url: URL) -> Bool {
        rz_path_metadata_walked(url.path)
    }

    /// Wraps an image as a single-"Background"-layer document.
    static func from(image: RasterImage) -> RasterDocument? {
        rz_doc_from_image(image.ptr).map { RasterDocument(owning: $0) }
    }

    func clone() -> RasterDocument? { wrap(rz_doc_clone(ptr)) }

    var width: Int { Int(rz_doc_width(ptr)) }
    var height: Int { Int(rz_doc_height(ptr)) }
    var canvasSize: NSSize { NSSize(width: width, height: height) }
    var layerCount: Int { Int(rz_doc_layer_count(ptr)) }

    /// Value snapshot of one ENTRY's metadata (index 0 = bottom entry). An
    /// entry is a raster layer or a GROUP; the structure fields are read here
    /// rather than one call at a time so the layers panel's per-row FFI count
    /// does not grow with the feature.
    struct LayerInfo {
        let name: String
        let opacity: Double
        let blendMode: RzBlendMode
        let visible: Bool
        /// The PIXEL BUFFER rect: a raster layer's offset and dimensions,
        /// and for a group — which has no buffer of its own — the union of
        /// its raster descendants' buffer rects. The CONTENT box (the opaque
        /// pixels) is `layerBounds`, which is a different rectangle and is
        /// asked for by name.
        let offsetX: Int
        let offsetY: Int
        let width: Int
        let height: Int
        let kind: RzLayerKind
        /// 0 at the top level, one more inside each enclosing group.
        let depth: Int
        /// An `RzLockFlags` bitmask; see `LayerLocks.swift`.
        let locks: UInt32
        /// Link-group id; 0 when unlinked.
        let link: UInt32
        /// Whether a GROUP is shown expanded. Always true on a raster entry.
        let open: Bool

        var isGroup: Bool { kind == RZ_LAYER_GROUP }
    }

    private func isValidIndex(_ idx: Int) -> Bool {
        idx >= 0 && idx < layerCount
    }

    private func wrap(_ result: OpaquePointer?) -> RasterDocument? {
        result.map { RasterDocument(owning: $0) }
    }

    private func wrapImage(_ result: OpaquePointer?) -> RasterImage? {
        result.map { RasterImage(owning: $0) }
    }

    func layerInfo(_ idx: Int) -> LayerInfo? {
        guard isValidIndex(idx) else { return nil }
        let i = idx
        var name = ""
        if let cName = rz_doc_layer_name(ptr, i) {
            name = String(cString: cName)
            rz_string_free(cName)
        }
        return LayerInfo(
            name: name,
            opacity: Double(rz_doc_layer_opacity(ptr, i)),
            blendMode: rz_doc_layer_blend_mode(ptr, i),
            visible: rz_doc_layer_visible(ptr, i),
            offsetX: Int(rz_doc_layer_offset_x(ptr, i)),
            offsetY: Int(rz_doc_layer_offset_y(ptr, i)),
            width: Int(rz_doc_layer_width(ptr, i)),
            height: Int(rz_doc_layer_height(ptr, i)),
            kind: rz_doc_layer_is_group(ptr, i) ? RZ_LAYER_GROUP : RZ_LAYER_RASTER,
            depth: Int(rz_doc_layer_depth(ptr, i)),
            locks: rz_doc_layer_locks(ptr, i),
            link: rz_doc_layer_link(ptr, i),
            open: rz_doc_layer_open(ptr, i))
    }

    /// Copy of a layer's pixels at the layer's own size.
    func layerImage(_ idx: Int) -> RasterImage? {
        guard isValidIndex(idx) else { return nil }
        return wrapImage(rz_doc_layer_image(ptr, idx))
    }

    /// Layer `idx`'s own straight RGBA8 bytes (width*height*4, row 0 = top),
    /// read back verbatim through rz_doc_layer_image — the pixel twin of
    /// `layerMaskCoverage`, for the byte-exact refits described layers make
    /// (no CoreGraphics round trip, so no premultiply loses low bits). nil
    /// for an out-of-range index or an empty layer.
    func layerPixels(_ idx: Int) -> [UInt8]? {
        guard isValidIndex(idx), let image = rz_doc_layer_image(ptr, idx) else {
            return nil
        }
        defer { rz_image_free(image) }
        let width = Int(rz_image_width(image))
        let height = Int(rz_image_height(image))
        guard width > 0, height > 0, let pixels = rz_image_pixels_rgba(image) else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: pixels, count: width * height * 4))
    }

    /// A layer's own pixels on a transparent canvas-sized image, placed at
    /// its offset — `flattened()` for a single layer, and what Copy puts on
    /// the clipboard. Opacity, blend mode, visibility and the mask are
    /// ignored: they say how the layer composites, not what its pixels are.
    func layerCanvasImage(_ idx: Int) -> RasterImage? {
        guard isValidIndex(idx) else { return nil }
        return wrapImage(rz_doc_layer_canvas_image(ptr, idx))
    }

    /// Aspect-fit thumbnail of a layer, longest side == maxSide.
    func layerThumbnail(_ idx: Int, maxSide: Int) -> RasterImage? {
        guard isValidIndex(idx), maxSide > 0 else { return nil }
        return wrapImage(rz_doc_layer_thumbnail(ptr, idx, UInt32(maxSide)))
    }

    /// Canvas-sized projection of the visible layers.
    func flattened() -> RasterImage? { wrapImage(rz_doc_flattened(ptr)) }

    // MARK: - Pure per-layer edits

    func withLayerName(_ idx: Int, _ name: String) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_name(ptr, idx, name))
    }

    func withLayerOpacity(_ idx: Int, _ opacity: Double) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_opacity(ptr, idx, Float(opacity)))
    }

    func withLayerBlendMode(_ idx: Int, _ mode: RzBlendMode) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_blend_mode(ptr, idx, mode))
    }

    func withLayerVisible(_ idx: Int, _ visible: Bool) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_visible(ptr, idx, visible))
    }

    /// `withLayerVisible(idx, false)` for the sweeps that hide a set of
    /// entries to compose a plate — the transform preview's below/above
    /// plates, the histogram's backdrop. An entry that is ALREADY hidden
    /// answers nil, because an op that changes nothing returns nothing (the
    /// core's purity rule), and that is not a failure here: it is the state
    /// the sweep asked for. Keeping the document instead of collapsing the
    /// chain is what stops one hidden layer from emptying a whole plate.
    func hidingLayer(_ idx: Int) -> RasterDocument {
        withLayerVisible(idx, false) ?? self
    }

    func withLayerOffset(_ idx: Int, _ x: Int, _ y: Int) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_offset(ptr, idx, Int32(clamping: x), Int32(clamping: y)))
    }

    /// Replaces a layer's pixels (any size; offset and properties kept).
    func withLayerPixels(_ idx: Int, _ image: RasterImage) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_pixels(ptr, idx, image.ptr))
    }

    /// The in-memory twin of `withLayerPixels`: replaces a layer's pixels
    /// from a STRAIGHT-alpha (non-premultiplied) RGBA8 buffer, row 0 = top,
    /// exactly `width * height * 4` bytes — not the premultiplied convention
    /// the painting overlay uses. The layer takes the buffer's size and keeps
    /// its offset, name, opacity, blend mode, visibility and metadata; as
    /// with `withLayerPixels`, a replacement at a DIFFERENT size drops the
    /// layer's mask (a mask is always exactly the layer's pixel size).
    func withLayerPixels(
        _ idx: Int, rgba pixels: [UInt8], width: Int, height: Int
    ) -> RasterDocument? {
        guard isValidIndex(idx), width > 0, height > 0,
              pixels.count == width * height * 4,
              width * height <= RasterImage.maxResizePixels
        else { return nil }
        return pixels.withUnsafeBufferPointer { buffer in
            wrap(
                rz_doc_with_layer_pixels_rgba(
                    ptr, idx, buffer.baseAddress, UInt32(width), UInt32(height)))
        }
    }

    /// The ONE-step twin of withLayerPixels + withLayerOffset (+ a mask):
    /// straight RGBA8 `pixels`, new offset, and `mask` (nil = the layer
    /// ends with no mask; a plane must be exactly width*height bytes) —
    /// rz_doc_set_layer_content, the re-render primitive behind described
    /// layers (DescribedLayer.swift). A given mask keeps the layer's
    /// mask-enabled flag; no mask resets it. nil on a bad size, a mask of
    /// the wrong length, or an out-of-range index.
    func setLayerContent(
        _ idx: Int, rgba pixels: [UInt8], width: Int, height: Int,
        offsetX: Int, offsetY: Int, mask: [UInt8]?
    ) -> RasterDocument? {
        guard isValidIndex(idx), width > 0, height > 0,
              pixels.count == width * height * 4,
              width * height <= RasterImage.maxResizePixels,
              mask == nil || mask?.count == width * height
        else { return nil }
        let x = Int32(clamping: offsetX)
        let y = Int32(clamping: offsetY)
        return pixels.withUnsafeBufferPointer { buffer in
            guard let mask = mask else {
                return wrap(
                    rz_doc_set_layer_content(
                        ptr, idx, buffer.baseAddress, UInt32(width), UInt32(height), x, y, nil))
            }
            return mask.withUnsafeBufferPointer { plane in
                wrap(
                    rz_doc_set_layer_content(
                        ptr, idx, buffer.baseAddress, UInt32(width), UInt32(height), x, y,
                        plane.baseAddress))
            }
        }
    }

    // MARK: - Layer metadata

    /// Layer `idx`'s metadata string, or nil when it carries none. The core
    /// stores this blob without ever parsing it; the schema is the app's
    /// (see TextLayer.swift).
    func layerMeta(_ idx: Int) -> String? {
        guard isValidIndex(idx), let cMeta = rz_doc_layer_meta(ptr, idx) else { return nil }
        defer { rz_string_free(cMeta) }
        return String(cString: cMeta)
    }

    /// Attaches `meta` to layer `idx`, or CLEARS its metadata when `meta` is
    /// nil. nil comes back for an over-long payload (the core caps it at
    /// 16 MiB, the native format's own limit).
    func withLayerMeta(_ idx: Int, _ meta: String?) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        guard let meta = meta else { return wrap(rz_doc_with_layer_meta(ptr, idx, nil)) }
        return wrap(rz_doc_with_layer_meta(ptr, idx, meta))
    }

    /// Whether layer `idx`'s metadata parses as a color-adjustment
    /// description ({"type":"adjust", ...} — the ONE meta shape the core
    /// itself interprets): such a layer composites as an adjustment of the
    /// backdrop and its own pixels are ignored. Asked of the CORE, whose
    /// parse is the compositor's, so the answer can never drift from what
    /// actually renders; the Swift-side parse (AdjustmentLayer.swift) is
    /// only for reading the op and params back into a dialog.
    func layerIsAdjustment(_ idx: Int) -> Bool {
        guard isValidIndex(idx) else { return false }
        return rz_doc_layer_is_adjustment(ptr, idx)
    }

    // MARK: - Stack operations

    /// Inserts a transparent canvas-sized layer ABOVE `idx`.
    func addingLayer(above idx: Int, name: String) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_adding_layer(ptr, idx, name))
    }

    /// Inserts `image` as a new layer ABOVE `idx`.
    func addingImageLayer(above idx: Int, _ image: RasterImage, name: String) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_adding_image_layer(ptr, idx, image.ptr, name))
    }

    func duplicatingLayer(_ idx: Int) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_duplicating_layer(ptr, idx))
    }

    /// nil when removing the last remaining layer.
    func removingLayer(_ idx: Int) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_removing_layer(ptr, idx))
    }

    func movingLayer(from: Int, to: Int) -> RasterDocument? {
        guard isValidIndex(from), isValidIndex(to) else { return nil }
        return wrap(rz_doc_moving_layer(ptr, from, to))
    }

    /// Merges layer `idx` (idx >= 1) into the layer below it.
    func mergingDown(_ idx: Int) -> RasterDocument? {
        guard idx >= 1, isValidIndex(idx) else { return nil }
        return wrap(rz_doc_merging_down(ptr, idx))
    }

    /// Single-layer document containing the projection.
    func flattening() -> RasterDocument? { wrap(rz_doc_flattening(ptr)) }

    /// Paints a CANVAS-frame premultiplied overlay (top row first, no row
    /// padding) onto layer `idx`, mapped through the layer's offset. `w`/`h`
    /// must equal the canvas size exactly.
    func paintingLayer(
        _ idx: Int, overlay data: UnsafePointer<UInt8>, w: Int, h: Int,
        mode: RzCompositeMode, alpha: Double
    ) -> RasterDocument? {
        guard isValidIndex(idx), w == width, h == height else { return nil }
        return wrap(rz_doc_painting_layer(ptr, idx, data, UInt32(w), UInt32(h), mode, Float(alpha)))
    }

    /// `paintingLayer`, through a layer blend mode — the paint tools' Blend
    /// option. Normal delegates to `paintingLayer` with `RZ_COMPOSITE_OVER`
    /// (byte-identical, refusal rules included); every OTHER mode also
    /// answers nil when no pixel would change.
    func paintingLayerBlend(
        _ idx: Int, overlay data: UnsafePointer<UInt8>, w: Int, h: Int,
        mode: RzBlendMode, alpha: Double
    ) -> RasterDocument? {
        guard isValidIndex(idx), w == width, h == height else { return nil }
        return wrap(
            rz_doc_painting_layer_blend(
                ptr, idx, data, UInt32(w), UInt32(h), mode, Float(alpha)))
    }

    /// Dodge/burn layer `idx` where the stroke overlay covers it — the same
    /// canvas-sized premultiplied overlay `paintingLayer` takes; only its
    /// alpha (the stroke's coverage) is read. `range`: 0 shadows, 1 midtones,
    /// 2 highlights. nil when nothing would change.
    func dodgeBurnLayer(
        _ idx: Int, overlay data: UnsafePointer<UInt8>, w: Int, h: Int,
        exposure: Double, range: Int, burn: Bool
    ) -> RasterDocument? {
        guard isValidIndex(idx), w == width, h == height, (0...2).contains(range) else {
            return nil
        }
        return wrap(
            rz_doc_dodge_burn_layer(
                ptr, idx, data, UInt32(w), UInt32(h), Float(exposure), UInt8(range), burn))
    }

    // MARK: - Layer groups, locks, links and structure

    /// The half-open range of entry `idx`'s subtree: the entry alone for a
    /// raster layer, the whole group for a group. nil for an out-of-range
    /// index.
    func layerSubtree(_ idx: Int) -> (start: Int, end: Int)? {
        guard isValidIndex(idx) else { return nil }
        var start = 0
        var end = 0
        guard rz_doc_layer_subtree(ptr, idx, &start, &end) else { return nil }
        return (start, end)
    }

    /// Where a new entry inserted ABOVE `idx` lands — the ONE answer every
    /// "select what I just made" site asks for, because `idx + 1` is the
    /// wrong index the moment `idx` names a group. Falls back to `idx + 1`
    /// only for an index the core does not recognize, where nothing was
    /// inserted anyway.
    func insertionIndex(above idx: Int) -> Int {
        layerSubtree(idx)?.end ?? idx + 1
    }

    /// True when entry `idx` is a GROUP.
    func layerIsGroup(_ idx: Int) -> Bool {
        guard isValidIndex(idx) else { return false }
        return rz_doc_layer_is_group(ptr, idx)
    }

    /// Entry `idx`'s nesting depth; 0 at the top level.
    func layerDepth(_ idx: Int) -> Int {
        guard isValidIndex(idx) else { return 0 }
        return Int(rz_doc_layer_depth(ptr, idx))
    }

    /// Entry `idx`'s lock flags as the raw `RzLockFlags` bitmask.
    func layerLocks(_ idx: Int) -> UInt32 {
        guard isValidIndex(idx) else { return 0 }
        return rz_doc_layer_locks(ptr, idx)
    }

    func withLayerLocks(_ idx: Int, _ locks: UInt32) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_locks(ptr, idx, locks))
    }

    /// Which of entry `idx`'s lock bits would block an edit of `kind`
    /// (0 = allowed) — what a refusal alert reads to NAME the lock. The core
    /// ops refuse regardless, so a path that forgets to ask still cannot
    /// write.
    func lockBlocking(_ idx: Int, kind: RzEditKind) -> UInt32 {
        guard isValidIndex(idx) else { return 0 }
        return rz_doc_lock_block(ptr, idx, kind)
    }

    /// Entry `idx`'s link-group id; 0 when unlinked.
    func layerLink(_ idx: Int) -> UInt32 {
        guard isValidIndex(idx) else { return 0 }
        return rz_doc_layer_link(ptr, idx)
    }

    /// Whether GROUP `idx` is shown expanded.
    func layerOpen(_ idx: Int) -> Bool {
        guard isValidIndex(idx) else { return false }
        return rz_doc_layer_open(ptr, idx)
    }

    func withLayerOpen(_ idx: Int, _ open: Bool) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_open(ptr, idx, open))
    }

    /// Entry `idx`'s CONTENT bounds — the canvas box of its opaque pixels,
    /// mask applied, and for a group the union over its descendants. This is
    /// what align and distribute act on, and it is NOT `LayerInfo`'s
    /// offset/width/height, which are a raster layer's pixel buffer rect.
    /// nil when nothing in the entry is opaque.
    func layerBounds(_ idx: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard isValidIndex(idx) else { return nil }
        var xywh = [Int32](repeating: 0, count: 4)
        guard xywh.withUnsafeMutableBufferPointer({ rz_doc_layer_bounds(ptr, idx, $0.baseAddress) })
        else { return nil }
        return (Int(xywh[0]), Int(xywh[1]), Int(xywh[2]), Int(xywh[3]))
    }

    /// The entry a click at canvas `point` activates: the topmost one whose
    /// own coverage there is at least half, adjustment layers skipped. With
    /// `topLevel` the answer is that entry's top-level ancestor
    /// (Auto-Select: Group). nil when nothing is hit — the caller then leaves
    /// its selection alone rather than emptying it.
    func layerAt(_ point: CGPoint, topLevel: Bool) -> Int? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        var idx = 0
        guard rz_doc_layer_at(ptr, Self.canvasCoordinate(point.x),
                              Self.canvasCoordinate(point.y), topLevel, &idx)
        else { return nil }
        return idx
    }

    /// A caller-supplied canvas coordinate narrowed to the `int32_t` the core
    /// takes. The clamp is done in DOUBLE arithmetic and never through `Int`:
    /// `Int(1e30)` traps ("Double value cannot be converted to Int because
    /// the result would be greater than Int.max") and kills the process, and
    /// this is reached from `auto_select_layer` with any finite number a
    /// model cares to send. Any coordinate that far out is off-canvas
    /// whichever extreme it lands on, so clamping answers the same "nothing
    /// there" the core would.
    private static func canvasCoordinate(_ v: CGFloat) -> Int32 {
        let floored = v.rounded(.down)
        if floored <= CGFloat(Int32.min) { return Int32.min }
        if floored >= CGFloat(Int32.max) { return Int32.max }
        return Int32(floored)
    }

    /// Every set op takes an explicit index list, validated here the way the
    /// core validates it: non-empty, in range and without repeats, since a
    /// repeat means the caller has miscounted and a silent dedupe would hide
    /// it. Ascending on the way through, which is the order the core wants.
    private func withIndices<T>(
        _ indices: [Int], _ body: (UnsafePointer<Int>?, Int) -> T?
    ) -> T? {
        let sorted = indices.sorted()
        guard !sorted.isEmpty, sorted.allSatisfy(isValidIndex),
              Set(sorted).count == sorted.count
        else { return nil }
        return sorted.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
    }

    /// Wraps `indices` — which must all share one parent — in a new group.
    /// Alongside the new document come the group's index and the two things
    /// the caller has to be able to report: the entries whose clipped flag
    /// was CLEARED (the bottom-most grouped entry loses a base that stayed
    /// outside) and the entries whose relative ORDER changed (a
    /// non-contiguous set gathers its subtrees into the topmost slot). Both
    /// are NEW indices.
    func groupLayers(
        _ indices: [Int], name: String
    ) -> (document: RasterDocument, group: Int, clearedClip: [Int], reordered: [Int])? {
        let cap = layerCount + 1
        var group = 0
        var cleared = [Int](repeating: 0, count: cap)
        var clearedLen = 0
        var reordered = [Int](repeating: 0, count: cap)
        var reorderedLen = 0
        let handle: OpaquePointer? = withIndices(indices) { buffer, count in
            cleared.withUnsafeMutableBufferPointer { clearedBuffer in
                reordered.withUnsafeMutableBufferPointer { reorderedBuffer in
                    rz_doc_group_layers(
                        ptr, buffer, count, name, &group,
                        clearedBuffer.baseAddress, &clearedLen,
                        reorderedBuffer.baseAddress, &reorderedLen, cap)
                }
            }
        }
        guard let document = wrap(handle) else { return nil }
        return (
            document, group,
            Array(cleared.prefix(min(clearedLen, cap))),
            Array(reordered.prefix(min(reorderedLen, cap)))
        )
    }

    /// Dissolves group `idx`; its children take its depth and its slot. The
    /// group's own mask, style, opacity, blend mode and clipped flag are
    /// discarded, so a caller reporting the loss must read them first.
    ///
    /// `clearedClip` is the mirror of `groupLayers`': the bottom-most child
    /// was baseless inside the group, so if it would gain a clip base out at
    /// the parent level its clipped flag is released instead — and the entry
    /// is named here (a NEW index) so the caller can report it.
    func ungroupLayer(
        _ idx: Int
    ) -> (document: RasterDocument, clearedClip: [Int])? {
        guard isValidIndex(idx) else { return nil }
        let cap = layerCount
        var cleared = [Int](repeating: 0, count: max(cap, 1))
        var clearedLen = 0
        let handle: OpaquePointer? = cleared.withUnsafeMutableBufferPointer { buffer in
            rz_doc_ungroup_layer(ptr, idx, buffer.baseAddress, &clearedLen, cap)
        }
        guard let document = wrap(handle) else { return nil }
        return (document, Array(cleared.prefix(min(clearedLen, cap))))
    }

    /// The structural move: entry `from` and its subtree land at `to` at
    /// `depth` — how a layer moves into or out of a group. `movingLayer`
    /// stays the drag-onto-a-row form that takes the destination's depth.
    func moveLayerTo(from: Int, to: Int, depth: Int) -> RasterDocument? {
        guard isValidIndex(from), isValidIndex(to), depth >= 0 else { return nil }
        return wrap(rz_doc_move_layer_to(ptr, from, to, UInt32(clamping: depth)))
    }

    /// Moves entry `idx` among its SIBLINGS only — never into or out of a
    /// group.
    func arrangeLayer(_ idx: Int, to how: RzArrange) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_arrange_layer(ptr, idx, how))
    }

    /// Links the given entries under one id; unlink clears theirs.
    func linkLayers(_ indices: [Int]) -> RasterDocument? {
        withIndices(indices) { buffer, count in wrap(rz_doc_link_layers(ptr, buffer, count)) }
    }

    func unlinkLayers(_ indices: [Int]) -> RasterDocument? {
        withIndices(indices) { buffer, count in wrap(rz_doc_unlink_layers(ptr, buffer, count)) }
    }

    /// Translates every given entry by (dx, dy) — the ONE move-a-set op, so
    /// subtrees and link groups follow and a position lock refuses the whole
    /// call.
    func moveLayers(_ indices: [Int], dx: Int, dy: Int) -> RasterDocument? {
        withIndices(indices) { buffer, count in
            wrap(rz_doc_move_layers(
                ptr, buffer, count, Int32(clamping: dx), Int32(clamping: dy)))
        }
    }

    /// The same affine applied to every given entry, each deriving its own
    /// destination extent; all or nothing.
    func transformLayers(
        _ indices: [Int], _ transform: CGAffineTransform, sampler: RzResizeFilter
    ) -> RasterDocument? {
        guard let affine = Self.affineElements(transform) else { return nil }
        return withIndices(indices) { buffer, count in
            affine.withUnsafeBufferPointer { elements in
                wrap(rz_doc_transform_layers(
                    ptr, buffer, count, elements.baseAddress, sampler))
            }
        }
    }

    /// The same affine applied to the WHOLE stack — the Crop tool's
    /// straighten, and the agent `crop` tool's.
    ///
    /// Not `transformLayers(Array(0..<layerCount), …)`: that call is
    /// all-or-nothing under per-entry POSITION locks, so one locked layer
    /// (the Background, which is the layer a Photoshop user locks by habit)
    /// refused an entire document-wide crop. Straightening re-frames the
    /// picture rather than moving a layer within it, which is why `cropped`,
    /// `rotated90`, `canvasResized` and `resized` do not consult a layer
    /// lock either. nil when nothing would change or an entry's transform
    /// refuses.
    func straightenLayers(
        _ transform: CGAffineTransform, sampler: RzResizeFilter
    ) -> RasterDocument? {
        guard let affine = Self.affineElements(transform) else { return nil }
        return affine.withUnsafeBufferPointer { elements in
            wrap(rz_doc_straighten_layers(ptr, elements.baseAddress, sampler))
        }
    }

    func duplicateLayers(_ indices: [Int]) -> RasterDocument? {
        withIndices(indices) { buffer, count in wrap(rz_doc_duplicate_layers(ptr, buffer, count)) }
    }

    func removeLayers(_ indices: [Int]) -> RasterDocument? {
        withIndices(indices) { buffer, count in wrap(rz_doc_remove_layers(ptr, buffer, count)) }
    }

    /// Photoshop's Merge Layers over a multi-selection: one raster entry at
    /// the lowest member's slot, through the projection's own kernel.
    func mergeLayers(_ indices: [Int]) -> RasterDocument? {
        withIndices(indices) { buffer, count in wrap(rz_doc_merge_layers(ptr, buffer, count)) }
    }

    /// Aligns the given entries' CONTENT bounds to `edge` of the selection's
    /// union, or of the canvas with `toCanvas`.
    func alignLayers(_ indices: [Int], edge: RzAlign, toCanvas: Bool) -> RasterDocument? {
        withIndices(indices) { buffer, count in
            wrap(rz_doc_align_layers(ptr, buffer, count, edge, toCanvas))
        }
    }

    /// Spaces the given entries evenly: the outermost two keep their places
    /// and the gaps between adjacent content bounds are equalized.
    func distributeLayers(_ indices: [Int], vertical: Bool) -> RasterDocument? {
        withIndices(indices) { buffer, count in
            wrap(rz_doc_distribute_layers(ptr, buffer, count, vertical))
        }
    }

    /// Replaces every entry that CONTRIBUTES to the projection with one
    /// canvas-sized raster entry holding it. A visible layer inside a hidden
    /// group contributes nothing and therefore SURVIVES.
    func mergeVisible() -> RasterDocument? { wrap(rz_doc_merge_visible(ptr)) }

    /// Adds the visible projection as a new entry above `above`'s subtree,
    /// leaving the rest of the stack alone.
    func stampVisible(above: Int, name: String) -> RasterDocument? {
        guard isValidIndex(above) else { return nil }
        return wrap(rz_doc_stamp_visible(ptr, above, name))
    }

    /// Layer Via Copy / Via Cut. This op RASTERIZES — it keeps neither the
    /// layer's metadata nor its style and refuses a group or an adjustment
    /// layer — so a caller whose target is a described layer wants
    /// `duplicatingLayer` instead. `mask` is a canvas-sized coverage buffer,
    /// or nil for the whole layer.
    func layerVia(_ idx: Int, mask: [UInt8]?, cut: Bool, name: String) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        guard let mask = mask else {
            return wrap(rz_doc_layer_via(
                ptr, idx, nil, UInt32(width), UInt32(height), cut, name))
        }
        guard mask.count == width * height else { return nil }
        return mask.withUnsafeBufferPointer { coverage in
            wrap(rz_doc_layer_via(
                ptr, idx, coverage.baseAddress, UInt32(width), UInt32(height), cut, name))
        }
    }

    // MARK: - Retouching

    /// The two-tier result of a core op that reports through `err_out`: NULL
    /// WITH a message is an error, NULL WITHOUT one is a plain refusal
    /// (nothing would change), and a handle is the new document. The idiom
    /// `withLayerStyle` spells out inline, shared by the retouching wrappers
    /// below — a non-NULL handle never comes back with a message, so nothing
    /// is leaked by not reading `err` on that path.
    private func fallible(
        _ handle: OpaquePointer?, _ err: UnsafeMutablePointer<CChar>?, _ fallback: String
    ) throws -> RasterDocument? {
        guard let handle = handle else {
            guard err != nil else { return nil }
            throw RasterCoreError(message: takeErrorMessage(err, fallback: fallback))
        }
        return RasterDocument(owning: handle)
    }

    /// Poisson-blends the source patch an overlay carries into layer `idx` —
    /// the healing brush. `overlay` is the same canvas-sized premultiplied
    /// buffer `paintingLayer` takes: its alpha is the footprint's coverage,
    /// its RGB the already-aligned source, so the Clone Stamp's overlay IS
    /// this op's input. Coverage below 128 is not written at all (hardness
    /// shrinks the footprint; the heal itself never fades), and `strength`
    /// — the tool's Opacity — scales the write-back. nil when nothing would
    /// change; throws the core's message when a healed region's box is over
    /// the documented memory limit.
    func healLayer(
        _ idx: Int, overlay data: UnsafePointer<UInt8>, w: Int, h: Int, strength: Double
    ) throws -> RasterDocument? {
        guard isValidIndex(idx), w == width, h == height, strength.isFinite else { return nil }
        var err: UnsafeMutablePointer<CChar>? = nil
        let handle = rz_doc_heal_layer(
            ptr, idx, data, UInt32(w), UInt32(h), Float(strength), &err)
        return try fallible(handle, err, "The heal could not be applied.")
    }

    /// Spot healing: the core inpaints the overlay's footprint from a ring
    /// around it and blends the result in as `healLayer` does. Only the
    /// overlay's ALPHA is read — there is no sampled source, so the overlay
    /// carries pure coverage. `ring` is the sampling-ring width in px (0 =
    /// automatic), `seed` makes the result reproducible, and `preview`
    /// computes the whole pipeline on a reduced copy. nil when nothing would
    /// change; throws the core's message on a cap or a starved sample region.
    func spotHealLayer(
        _ idx: Int, overlay data: UnsafePointer<UInt8>, w: Int, h: Int, strength: Double,
        ring: Int, seed: UInt64, sampleAllLayers: Bool, preview: Bool
    ) throws -> RasterDocument? {
        guard isValidIndex(idx), w == width, h == height, strength.isFinite else { return nil }
        var err: UnsafeMutablePointer<CChar>? = nil
        let handle = rz_doc_spot_heal_layer(
            ptr, idx, data, UInt32(w), UInt32(h), Float(strength),
            UInt32(clamping: max(0, ring)), seed, sampleAllLayers, preview, &err)
        return try fallible(handle, err, "The spot heal could not be applied.")
    }

    /// Content-Aware Fill over `mask`, a canvas-sized coverage buffer (the
    /// one fill and gradient take): the core inpaints the marked region from
    /// a ring around it and blends it to the surrounding illumination. The
    /// region is every pixel the mask touches at all and its soft bytes
    /// weight the write-back, so a feathered selection is filled and faded
    /// across the whole of its ramp and nothing outside it moves. nil when
    /// nothing would change;
    /// throws the core's message on a cap or a starved sample region.
    func contentAwareFilled(
        _ idx: Int, mask: [UInt8], ring: Int, seed: UInt64, sampleAllLayers: Bool, preview: Bool
    ) throws -> RasterDocument? {
        guard isValidIndex(idx), mask.count == width * height else { return nil }
        var err: UnsafeMutablePointer<CChar>? = nil
        let handle = mask.withUnsafeBufferPointer { buffer in
            rz_doc_content_aware_fill(
                ptr, idx, buffer.baseAddress, UInt32(width), UInt32(height),
                UInt32(clamping: max(0, ring)), seed, sampleAllLayers, preview, &err)
        }
        return try fallible(handle, err, "The fill could not be applied.")
    }

    /// Removes flash red inside a canvas rect on layer `idx`: red dominance
    /// gated by saturation and hue, corrected only where a scoring component
    /// fits within `pupilSize` (a fraction, 1.0 = the default) of the rect's
    /// SHORTER side and does not reach all four of its sides. `darken` is
    /// 0…1 (0.5 = Photoshop's default). nil on an empty or off-canvas rect,
    /// on nothing red inside it, on no component the rect contains and
    /// admits under `pupilSize`, or when nothing would change.
    func redEyeLayer(
        _ idx: Int, rect: CGRect, pupilSize: Double, darken: Double
    ) -> RasterDocument? {
        guard isValidIndex(idx), !rect.isNull, !rect.isInfinite, !rect.isEmpty,
            rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
            pupilSize.isFinite, darken.isFinite
        else { return nil }
        // Clamp in DOUBLE space, before any integer conversion. `Int(_:)`
        // TRAPS — it does not saturate — on a finite Double outside Int64's
        // range, and the trap kills the process with every open document's
        // unsaved work; `red_eye {"x": 1e300, …}` and an `eyes` entry with a
        // huge radius both reached it. A canvas coordinate past ±2 × 10⁹
        // cannot name a pixel of any document this app can hold (`MAX_PIXELS`
        // is 100 million), so the clamp discards nothing real, and the agent
        // handlers wall the arguments far below it so a caller gets a
        // sentence rather than a silent clamp.
        let x = Int32(clamping: Int(Self.pixelCoordinate(rect.minX.rounded(.down))))
        let y = Int32(clamping: Int(Self.pixelCoordinate(rect.minY.rounded(.down))))
        let w = UInt32(clamping: Int(Self.pixelCoordinate(rect.width.rounded())))
        let h = UInt32(clamping: Int(Self.pixelCoordinate(rect.height.rounded())))
        guard w > 0, h > 0 else { return nil }
        return wrap(
            rz_doc_red_eye_layer(ptr, idx, x, y, w, h, Float(pupilSize), Float(darken)))
    }

    /// A finite canvas coordinate brought inside the range `Int(_:)` can
    /// convert without trapping. NaN is already excluded by the callers'
    /// `isFinite` guards; this handles the finite-but-astronomical case that
    /// a JSON number in scientific notation makes trivial to send.
    private static func pixelCoordinate(_ value: Double) -> Double {
        min(max(value, -2_000_000_000), 2_000_000_000)
    }

    // MARK: - Selection regions and region painting

    /// Similar-color mask from the flattened composite: canvas-sized
    /// 0/255 bytes (row 0 top), or nil for an out-of-canvas seed.
    func magicWand(x: Int, y: Int, tolerance: Int, contiguous: Bool) -> [UInt8]? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        var mask = [UInt8](repeating: 0, count: width * height)
        let ok = mask.withUnsafeMutableBufferPointer { buffer in
            rz_doc_magic_wand(
                ptr, UInt32(x), UInt32(y), UInt8(tolerance.clamped(0, 255)),
                contiguous, buffer.baseAddress)
        }
        return ok ? mask : nil
    }

    /// Bucket fill on layer `idx` from canvas point (x, y). `mask` is a
    /// canvas-sized selection coverage buffer or nil.
    func bucketFilled(
        _ idx: Int, x: Int, y: Int, tolerance: Int, rgba: [UInt8], contiguous: Bool,
        mask: [UInt8]?
    ) -> RasterDocument? {
        guard isValidIndex(idx), rgba.count == 4 else { return nil }
        return withMask(mask) { maskPtr in
            rgba.withUnsafeBufferPointer { color in
                wrap(
                    rz_doc_bucket_fill(
                        ptr, idx, Int32(x), Int32(y), UInt8(tolerance.clamped(0, 255)),
                        color.baseAddress, contiguous, maskPtr))
            }
        }
    }

    /// Two-color gradient over layer `idx` (scaled by `mask` if given).
    func gradiented(
        _ idx: Int, from p0: CGPoint, to p1: CGPoint, start: [UInt8], end: [UInt8],
        kind: RzGradientKind, mask: [UInt8]?
    ) -> RasterDocument? {
        guard isValidIndex(idx), start.count == 4, end.count == 4 else { return nil }
        return withMask(mask) { maskPtr in
            start.withUnsafeBufferPointer { s in
                end.withUnsafeBufferPointer { e in
                    wrap(
                        rz_doc_gradient(
                            ptr, idx, Float(p0.x), Float(p0.y), Float(p1.x), Float(p1.y),
                            s.baseAddress, e.baseAddress, kind, maskPtr))
                }
            }
        }
    }

    /// Erases the selected region of layer `idx` in PROPORTION to the
    /// selection's coverage: `mask` is a canvas-sized coverage buffer (the
    /// one fill and gradient take), so full coverage erases a pixel, partial
    /// coverage scales its alpha down — a feathered selection cuts a
    /// soft-edged hole. Everything else about the layer survives.
    func clearingSelection(_ idx: Int, mask: [UInt8]) -> RasterDocument? {
        guard isValidIndex(idx), mask.count == width * height else { return nil }
        return mask.withUnsafeBufferPointer { buffer in
            wrap(
                rz_doc_clear_selection(
                    ptr, idx, buffer.baseAddress, UInt32(width), UInt32(height)))
        }
    }

    private func withMask<T>(_ mask: [UInt8]?, _ body: (UnsafePointer<UInt8>?) -> T) -> T {
        guard let mask = mask, mask.count == width * height else { return body(nil) }
        return mask.withUnsafeBufferPointer { body($0.baseAddress) }
    }

    // MARK: - Layer masks

    /// Gives layer `idx` a mask (replacing any existing one) and enables it,
    /// at exactly the layer's pixel size. `selection` is a CANVAS-sized
    /// coverage buffer, required by `RZ_MASK_FROM_SELECTION` (it is cropped
    /// to the layer) and unused — pass nil — by the other kinds.
    func addingLayerMask(
        _ idx: Int, kind: RzMaskKind, selection: [UInt8]? = nil
    ) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        guard kind == RZ_MASK_FROM_SELECTION else {
            return wrap(rz_doc_adding_layer_mask(ptr, idx, kind, nil, 0, 0))
        }
        guard let selection = selection, selection.count == width * height else { return nil }
        return selection.withUnsafeBufferPointer { buffer in
            wrap(
                rz_doc_adding_layer_mask(
                    ptr, idx, kind, buffer.baseAddress, UInt32(width), UInt32(height)))
        }
    }

    /// Drops layer `idx`'s mask. With `apply` the coverage is first baked
    /// into the layer's alpha (regardless of the enabled flag).
    func removingLayerMask(_ idx: Int, apply: Bool) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_removing_layer_mask(ptr, idx, apply))
    }

    /// Enables or disables layer `idx`'s mask; a disabled mask is retained
    /// (and saved) but ignored while compositing.
    func withLayerMaskEnabled(_ idx: Int, _ enabled: Bool) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_mask_enabled(ptr, idx, enabled))
    }

    /// Paints layer `idx`'s MASK with a CANVAS-frame premultiplied overlay —
    /// the very buffer `paintingLayer` takes — mapped through the layer's
    /// offset: white reveals, black hides, the overlay's alpha is the blend.
    func paintingLayerMask(
        _ idx: Int, overlay data: UnsafePointer<UInt8>, w: Int, h: Int
    ) -> RasterDocument? {
        guard isValidIndex(idx), w == width, h == height else { return nil }
        return wrap(rz_doc_painting_layer_mask(ptr, idx, data, UInt32(w), UInt32(h)))
    }

    /// Layer `idx`'s mask as an opaque grayscale image at the LAYER's size
    /// (the source for the mask thumbnail); nil when the layer has no mask.
    func layerMaskImage(_ idx: Int) -> RasterImage? {
        guard isValidIndex(idx) else { return nil }
        return wrapImage(rz_doc_layer_mask_image(ptr, idx))
    }

    /// Layer `idx`'s mask as a coverage plane (width*height bytes, row 0 =
    /// top — the selection convention at the LAYER's size), read back
    /// through rz_doc_layer_mask_image (opaque grayscale RGBA: the red
    /// channel is the coverage). nil without a mask.
    func layerMaskCoverage(_ idx: Int) -> [UInt8]? {
        guard isValidIndex(idx), let image = rz_doc_layer_mask_image(ptr, idx) else {
            return nil
        }
        defer { rz_image_free(image) }
        let width = Int(rz_image_width(image))
        let height = Int(rz_image_height(image))
        guard width > 0, height > 0, let pixels = rz_image_pixels_rgba(image) else {
            return nil
        }
        var plane = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            plane[i] = pixels[i * 4]
        }
        return plane
    }

    func layerHasMask(_ idx: Int) -> Bool {
        guard isValidIndex(idx) else { return false }
        return rz_doc_layer_has_mask(ptr, idx)
    }

    /// True only for a layer that HAS a mask and has it enabled, so it can
    /// drive a checkbox or menu item state directly.
    func layerMaskEnabled(_ idx: Int) -> Bool {
        guard isValidIndex(idx) else { return false }
        return rz_doc_layer_mask_enabled(ptr, idx)
    }

    // MARK: - Channels and planes

    /// Value snapshot of one alpha channel (see the header's "Channels"
    /// section): a named canvas-sized coverage plane plus the rubylith a host
    /// draws it with. The plane itself comes from `channelPlane` or
    /// `channelImage`.
    struct ChannelInfo {
        /// The core's stable per-channel identity: unique while the app runs,
        /// kept through a rename, a plane edit, the geometry ops and
        /// undo/redo, fresh for a duplicate, and gone when the channel is.
        /// It is how view state (which channel's eye is on) stays attached to
        /// a channel — names are not unique and indices renumber on every
        /// insert, delete and undo.
        let id: UInt64
        let name: String
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let opacity: Double
        /// false = the rubylith covers the MASKED areas (the default, and
        /// what the Quick Mask overlay already draws).
        let colorIndicatesSelected: Bool
    }

    var channelCount: Int { Int(rz_doc_channel_count(ptr)) }

    /// The largest channel count a `w` x `h` canvas may carry: the core's own
    /// budget (256 channels, and 900 M channel pixels in total — nine full
    /// canvases), asked as a number so a refusal can name it. Image Size,
    /// Canvas Size and every channel-creating command refuse on it, and a beep
    /// alone leaves the user no way to learn why.
    /// A size past what a canvas can be answers 0 — nothing fits a canvas
    /// that could not exist in the first place.
    static func maxChannels(width w: Int, height h: Int) -> Int {
        guard w >= 0, h >= 0, w <= Int(UInt32.max), h <= Int(UInt32.max) else { return 0 }
        return Int(rz_max_channels_at(UInt32(w), UInt32(h)))
    }

    private func isValidChannel(_ i: Int) -> Bool {
        i >= 0 && i < channelCount
    }

    /// Channel `i`'s stable identity alone (see `ChannelInfo.id`), 0 for an
    /// out-of-range index. The cheap half of `channelInfo` — no name string
    /// crosses the boundary — for the view state that only needs identity.
    func channelID(_ i: Int) -> UInt64 {
        guard isValidChannel(i) else { return 0 }
        return rz_doc_channel_id(ptr, i)
    }

    func channelInfo(_ i: Int) -> ChannelInfo? {
        guard isValidChannel(i) else { return nil }
        var name = ""
        if let cName = rz_doc_channel_name(ptr, i) {
            name = String(cString: cName)
            rz_string_free(cName)
        }
        var rgb = [UInt8](repeating: 0, count: 3)
        let ok = rgb.withUnsafeMutableBufferPointer { buffer in
            rz_doc_channel_overlay_color(ptr, i, buffer.baseAddress)
        }
        guard ok else { return nil }
        return ChannelInfo(
            id: rz_doc_channel_id(ptr, i),
            name: name, red: rgb[0], green: rgb[1], blue: rgb[2],
            opacity: Double(rz_doc_channel_overlay_opacity(ptr, i)),
            colorIndicatesSelected: rz_doc_channel_color_indicates_selected(ptr, i))
    }

    /// A canvas-sized plane read STRAIGHT into a Swift buffer — never through
    /// an image handle, which would cost five times the memory for bytes that
    /// are u8 coverage to begin with.
    private func readCanvasPlane(_ read: (UnsafeMutablePointer<UInt8>?) -> Bool) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        var plane = [UInt8](repeating: 0, count: width * height)
        let ok = plane.withUnsafeMutableBufferPointer { read($0.baseAddress) }
        return ok ? plane : nil
    }

    /// Channel `i`'s coverage bytes (canvas-sized, row 0 = top — the
    /// selection convention).
    func channelPlane(_ i: Int) -> [UInt8]? {
        guard isValidChannel(i) else { return nil }
        return readCanvasPlane { out in
            rz_doc_channel_plane(ptr, i, out, UInt32(width), UInt32(height))
        }
    }

    /// One plane of the FLATTENED composite, canvas-sized. A ONE-SHOT read:
    /// it runs the whole projection, so a display path reads the cached
    /// projection with `RasterImage.plane` instead. nil for `RZ_PLANE_MASK`.
    func compositePlane(_ plane: RzPlane) -> [UInt8]? {
        readCanvasPlane { out in
            rz_doc_composite_plane(ptr, plane, out, UInt32(width), UInt32(height))
        }
    }

    /// One plane of layer `idx`, CANVAS-sized: pixels outside the layer's
    /// rect read 0, `RZ_PLANE_MASK` included. nil when the layer has no mask
    /// and `RZ_PLANE_MASK` was asked for.
    func layerPlane(_ idx: Int, _ plane: RzPlane) -> [UInt8]? {
        guard isValidIndex(idx) else { return nil }
        return readCanvasPlane { out in
            rz_doc_layer_plane(ptr, idx, plane, out, UInt32(width), UInt32(height))
        }
    }

    /// One-shot plane image (it re-flattens). For a DISPLAY path use
    /// `RasterImage.planeImage` on the cached projection instead.
    /// `maxSide` 0 means full size.
    func compositePlaneImage(_ plane: RzPlane, maxSide: Int) -> RasterImage? {
        guard maxSide >= 0 else { return nil }
        return wrapImage(rz_doc_composite_plane_image(ptr, plane, UInt32(maxSide)))
    }

    /// One CANVAS-sized plane of layer `idx` as an opaque grayscale image.
    func layerPlaneImage(_ idx: Int, _ plane: RzPlane, maxSide: Int) -> RasterImage? {
        guard isValidIndex(idx), maxSide >= 0 else { return nil }
        return wrapImage(rz_doc_layer_plane_image(ptr, idx, plane, UInt32(maxSide)))
    }

    /// Channel `i` as an opaque grayscale image — the panel's thumbnail
    /// source (the core does the downsampling; `maxSide` 0 means full size).
    func channelImage(_ i: Int, maxSide: Int) -> RasterImage? {
        guard isValidChannel(i), maxSide >= 0 else { return nil }
        return wrapImage(rz_doc_channel_image(ptr, i, UInt32(maxSide)))
    }

    /// Appends a channel from `plane` (`width * height` coverage bytes). A
    /// plane that is not canvas-sized is resampled to the canvas bilinearly —
    /// the iPhone auxiliary-matte path. nil when the list is full or the nine
    /// would not fit the total pixel budget.
    func addingChannel(
        name: String, plane: [UInt8], width w: Int, height h: Int,
        red: UInt8 = 255, green: UInt8 = 0, blue: UInt8 = 0, opacity: Double = 0.5
    ) -> RasterDocument? {
        guard w > 0, h > 0, plane.count == w * h else { return nil }
        return plane.withUnsafeBufferPointer { buffer in
            wrap(
                rz_doc_add_channel(
                    ptr, name, buffer.baseAddress, UInt32(w), UInt32(h),
                    red, green, blue, Float(opacity)))
        }
    }

    func removingChannel(_ i: Int) -> RasterDocument? {
        guard isValidChannel(i) else { return nil }
        return wrap(rz_doc_remove_channel(ptr, i))
    }

    /// nil for a name the channel already has (renaming to itself is not an
    /// edit).
    func renamingChannel(_ i: Int, _ name: String) -> RasterDocument? {
        guard isValidChannel(i) else { return nil }
        return wrap(rz_doc_rename_channel(ptr, i, name))
    }

    /// All the display options at once, so the options sheet is one undo
    /// step. nil when none of them would change.
    func settingChannelOverlay(
        _ i: Int, red: UInt8, green: UInt8, blue: UInt8, opacity: Double,
        indicatesSelected: Bool
    ) -> RasterDocument? {
        guard isValidChannel(i) else { return nil }
        return wrap(
            rz_doc_set_channel_overlay(
                ptr, i, red, green, blue, Float(opacity), indicatesSelected))
    }

    /// Replaces channel `i`'s coverage with a CANVAS-sized plane; nil when
    /// the bytes are what the channel already holds.
    func settingChannelData(_ i: Int, _ plane: [UInt8]) -> RasterDocument? {
        guard isValidChannel(i), plane.count == width * height else { return nil }
        return plane.withUnsafeBufferPointer { buffer in
            wrap(
                rz_doc_set_channel_data(
                    ptr, i, buffer.baseAddress, UInt32(width), UInt32(height)))
        }
    }

    func duplicatingChannel(_ i: Int) -> RasterDocument? {
        guard isValidChannel(i) else { return nil }
        return wrap(rz_doc_duplicate_channel(ptr, i))
    }

    func invertingChannel(_ i: Int) -> RasterDocument? {
        guard isValidChannel(i) else { return nil }
        return wrap(rz_doc_invert_channel(ptr, i))
    }

    /// Appends the nine luminosity masks ("Lights 1".."Midtones 3") built
    /// from the composite's Rec. 709 luma; nil when they would not fit.
    func addingLuminosityMasks() -> RasterDocument? {
        wrap(rz_doc_add_luminosity_masks(ptr))
    }

    /// Replaces ONLY `plane` of layer `idx`'s pixels from a CANVAS-sized
    /// buffer, inside the layer's rect. nil for `RZ_PLANE_LUMA`/
    /// `RZ_PLANE_MASK` and — importantly — when NO BYTE WOULD CHANGE, so a
    /// caller writing red, green and blue in turn must fall through per
    /// plane rather than chain the optionals.
    func withLayerPlane(_ idx: Int, _ plane: RzPlane, _ src: [UInt8]) -> RasterDocument? {
        guard isValidIndex(idx), src.count == width * height else { return nil }
        return src.withUnsafeBufferPointer { buffer in
            wrap(
                rz_doc_with_layer_plane(
                    ptr, idx, plane, buffer.baseAddress, UInt32(width), UInt32(height)))
        }
    }

    /// Replaces ONLY `plane` of layer `idx`'s pixels from a LAYER-SIZED
    /// buffer — `src` is `w * h` bytes of the layer's OWN pixel grid — and
    /// writes every sample, the part of the layer that hangs off the canvas
    /// included. The writer for the filter/adjustment round trip, whose
    /// source is `layerSpacePlaneImage` at that same size; `withLayerPlane`
    /// is the canvas-sized sibling. nil for the derived planes, for a
    /// buffer that is not the layer's size, and when no byte would change.
    func withLayerSpacePlane(
        _ idx: Int, _ plane: RzPlane, _ src: [UInt8], width w: Int, height h: Int
    ) -> RasterDocument? {
        guard isValidIndex(idx), w > 0, h > 0, src.count == w * h else { return nil }
        return src.withUnsafeBufferPointer { buffer in
            wrap(
                rz_doc_with_layer_space_plane(
                    ptr, idx, plane, buffer.baseAddress, UInt32(w), UInt32(h)))
        }
    }

    /// Paints channel `i` with a CANVAS-frame premultiplied overlay — the
    /// very buffer `paintingLayer` takes: white paints toward 255, black
    /// toward 0. nil when no byte would change.
    func paintingChannel(
        _ i: Int, overlay data: UnsafePointer<UInt8>, w: Int, h: Int
    ) -> RasterDocument? {
        guard isValidChannel(i), w == width, h == height else { return nil }
        return wrap(rz_doc_painting_channel(ptr, i, data, UInt32(w), UInt32(h)))
    }

    /// The same coverage paint into ONE colour plane of layer `idx`. nil for
    /// `RZ_PLANE_LUMA`/`RZ_PLANE_MASK` or when no byte would change.
    func paintingLayerPlane(
        _ idx: Int, _ plane: RzPlane, overlay data: UnsafePointer<UInt8>, w: Int, h: Int
    ) -> RasterDocument? {
        guard isValidIndex(idx), w == width, h == height else { return nil }
        return wrap(rz_doc_painting_layer_plane(ptr, idx, plane, data, UInt32(w), UInt32(h)))
    }

    // MARK: - Clipping masks

    /// Sets or clears layer `idx`'s clipped flag: a clipped layer is
    /// confined to the alpha footprint of the first UNCLIPPED layer beneath
    /// it (Photoshop clipping-mask semantics). Grouping is positional and
    /// re-derived at every composite, so reordering or deleting layers needs
    /// no bookkeeping here; a clipped BOTTOM layer has no base and
    /// composites as if unclipped.
    func withLayerClipped(_ idx: Int, clipped: Bool) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_clipped(ptr, idx, clipped))
    }

    func layerClipped(_ idx: Int) -> Bool {
        guard isValidIndex(idx) else { return false }
        return rz_doc_layer_clipped(ptr, idx)
    }

    // MARK: - Layer styles

    /// Layer `idx`'s style as the core's canonical JSON, or nil when it has
    /// none. The core is the authority on the schema (core/src/style.rs);
    /// LayerStyle.swift reads it back into a typed value for the dialog.
    func layerStyle(_ idx: Int) -> String? {
        guard isValidIndex(idx), let cStyle = rz_doc_layer_style(ptr, idx) else { return nil }
        defer { rz_string_free(cStyle) }
        return String(cString: cStyle)
    }

    /// Whether layer `idx` carries a style — the cheap badge query. Because
    /// the core never stores an identity style, true means the layer renders
    /// something.
    func layerHasStyle(_ idx: Int) -> Bool {
        guard isValidIndex(idx) else { return false }
        return rz_doc_layer_has_style(ptr, idx)
    }

    /// Attaches a style (canonical or not — the core canonicalizes) to layer
    /// `idx`, or CLEARS it when `json` is nil (an identity style also
    /// clears). nil for an out-of-range index or a value equal to the
    /// current one (the core refuses identical copies, so no phantom undo
    /// step); throws with the core's message when the JSON is not a valid
    /// style. `ptr` is never NULL here, so the core's "document is NULL"
    /// message cannot occur on this path.
    func withLayerStyle(_ idx: Int, _ json: String?) throws -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        var err: UnsafeMutablePointer<CChar>? = nil
        let handle: OpaquePointer?
        if let json = json {
            handle = rz_doc_set_layer_style(ptr, idx, json, &err)
        } else {
            handle = rz_doc_set_layer_style(ptr, idx, nil, &err)
        }
        guard let handle = handle else {
            // NULL with no message is the refusal tier (unchanged value).
            guard err != nil else { return nil }
            throw RasterCoreError(
                message: takeErrorMessage(err, fallback: "Invalid layer style."))
        }
        return RasterDocument(owning: handle)
    }

    /// The document's global light, degrees: the direction every effect with
    /// use_global_light on reads (0 = from the right, 90 = from the top;
    /// altitude 0…90).
    var globalLightAngle: Double { Double(rz_doc_global_light_angle(ptr)) }
    var globalLightAltitude: Double { Double(rz_doc_global_light_altitude(ptr)) }

    /// nil on a non-finite value or no change after the core's sanitizing
    /// (altitude clamped to 0…90, angle normalized to -180…180).
    func withGlobalLight(angle: Double, altitude: Double) -> RasterDocument? {
        wrap(rz_doc_set_global_light(ptr, Float(angle), Float(altitude)))
    }

    // MARK: - Whole-document geometry

    func rotated90() -> RasterDocument? { wrap(rz_doc_rotate90(ptr)) }
    func rotated180() -> RasterDocument? { wrap(rz_doc_rotate180(ptr)) }
    func rotated270() -> RasterDocument? { wrap(rz_doc_rotate270(ptr)) }
    func flippedH() -> RasterDocument? { wrap(rz_doc_flip_horizontal(ptr)) }
    func flippedV() -> RasterDocument? { wrap(rz_doc_flip_vertical(ptr)) }

    func cropped(x: Int, y: Int, w: Int, h: Int) -> RasterDocument? {
        guard x >= 0, y >= 0, w > 0, h > 0, x + w <= width, y + h <= height else { return nil }
        return wrap(rz_doc_crop(ptr, UInt32(x), UInt32(y), UInt32(w), UInt32(h)))
    }

    func resized(w: Int, h: Int, filter: RzResizeFilter) -> RasterDocument? {
        guard w > 0, h > 0, w * h <= RasterImage.maxResizePixels else { return nil }
        return wrap(rz_doc_resize(ptr, UInt32(w), UInt32(h), filter))
    }

    /// Changes the canvas size without scaling; (originX, originY) is where
    /// the old canvas's top-left lands in the new canvas.
    func canvasResized(w: Int, h: Int, originX: Int, originY: Int) -> RasterDocument? {
        guard w > 0, h > 0, w * h <= RasterImage.maxResizePixels else { return nil }
        return wrap(rz_doc_canvas_resize(ptr, UInt32(w), UInt32(h), Int32(originX), Int32(originY)))
    }

    /// Free transform of ONE layer by an arbitrary affine matrix, resampled
    /// with `sampler`. The matrix works in CANVAS coordinates — it says where
    /// the layer's canvas rect lands — and its six elements cross the FFI in
    /// CGAffineTransform order, [a, b, c, d, tx, ty], so a CGAffineTransform
    /// passes straight through. The layer's new offset and size are the
    /// outward-rounded bounding box of the transformed corners; its mask,
    /// name, opacity, blend mode, visibility and metadata survive (dropping a
    /// text description is the caller's policy). nil for a singular or
    /// non-finite matrix, an out-of-range index, or an extent the core caps.
    func transformingLayer(
        _ idx: Int, _ transform: CGAffineTransform, sampler: RzResizeFilter
    ) -> RasterDocument? {
        guard isValidIndex(idx), let affine = Self.affineElements(transform) else { return nil }
        return affine.withUnsafeBufferPointer { buffer in
            wrap(rz_doc_transform_layer(ptr, idx, buffer.baseAddress, sampler))
        }
    }

    /// The whole-document half of `transformingLayer`, for the one edit that
    /// turns the picture in place: the Crop tool's straighten rotates every
    /// layer (and its mask) about a point, and the alpha channels — saved
    /// selections OF that picture — have to ride the same matrix or they
    /// silently stop lining up with what they were saved from. Channels stay
    /// canvas-sized; coverage rotated off the canvas is dropped, which the
    /// straighten's own crop would have dropped anyway. nil when the document
    /// has no channels, so a caller chains it with `?? current`.
    func transformingChannels(
        _ transform: CGAffineTransform, sampler: RzResizeFilter
    ) -> RasterDocument? {
        guard let affine = Self.affineElements(transform) else { return nil }
        return affine.withUnsafeBufferPointer { buffer in
            wrap(rz_doc_transform_channels(ptr, buffer.baseAddress, sampler))
        }
    }

    /// The six elements in the order the FFI reads them, [a, b, c, d, tx,
    /// ty]; nil when any is not finite (a matrix the core would refuse).
    private static func affineElements(_ transform: CGAffineTransform) -> [Double]? {
        let affine: [Double] = [
            Double(transform.a), Double(transform.b), Double(transform.c),
            Double(transform.d), Double(transform.tx), Double(transform.ty),
        ]
        return affine.allSatisfy({ $0.isFinite }) ? affine : nil
    }

    /// Perspective transform of ONE layer: maps its canvas rect
    /// corner-for-corner onto `quad` — four canvas points in the source
    /// rect's corner order TL, TR, BR, BL. The homography is solved in the
    /// core; a parallelogram quad delegates to the affine path, exact fast
    /// paths included, and everything `transformingLayer` preserves
    /// survives here too. nil for a non-finite coordinate, a concave,
    /// self-intersecting or collapsed quad, an out-of-range index, or an
    /// extent the core caps.
    func perspectiveLayer(
        _ idx: Int, quad: [CGPoint], sampler: RzResizeFilter
    ) -> RasterDocument? {
        guard isValidIndex(idx), quad.count == 4 else { return nil }
        let corners: [Double] = quad.flatMap { [Double($0.x), Double($0.y)] }
        guard corners.allSatisfy({ $0.isFinite }) else { return nil }
        return corners.withUnsafeBufferPointer { buffer in
            wrap(rz_doc_perspective_layer(ptr, idx, buffer.baseAddress, sampler))
        }
    }

    /// Writes the native RZDC format (all layers preserved).
    func saveNative(to url: URL) throws {
        var err: UnsafeMutablePointer<CChar>? = nil
        guard rz_doc_save_native(ptr, url.path, &err) else {
            throw RasterCoreError(
                message: takeErrorMessage(err, fallback: "Could not save \(url.lastPathComponent)."))
        }
    }

    // MARK: - Colour management and metadata

    /// A variable-length blob read STRAIGHT into a Data: ask the core its
    /// length, allocate exactly that, fill it. The `len` the core takes back
    /// is a capacity check, never the authority — the ONE shape every blob
    /// getter below uses.
    private static func readBlob(
        _ length: () -> Int, _ fill: (UnsafeMutablePointer<UInt8>, Int) -> Bool
    ) -> Data? {
        let len = length()
        guard len > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: len)
        let ok = bytes.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return fill(base, len)
        }
        return ok ? Data(bytes) : nil
    }

    /// The document's ICC profile bytes — what a CGColorSpace is built from
    /// and what an export embeds. A document ALWAYS has a profile, so nil
    /// means only that the read failed.
    ///
    /// Read once and kept: a handle's pixels and profile never change (every
    /// core op returns a NEW handle), while `colorSpace` is asked on every
    /// redraw and once per layer and channel row, and each ask was copying
    /// the whole profile out of the core and hashing it. Cheap for the usual
    /// half-kilobyte profile, but a document can legitimately carry
    /// megabytes of one. Safe unlocked on the same terms as `flattened()` —
    /// one queue at a time touches a handle.
    var iccProfile: Data? {
        RasterDocument.iccLock.lock()
        defer { RasterDocument.iccLock.unlock() }
        if let cached = cachedICCProfile { return cached }
        let read = RasterDocument.readBlob({ rz_doc_icc_profile_len(ptr) }) { base, len in
            rz_doc_icc_profile(ptr, base, len)
        }
        cachedICCProfile = .some(read)
        return read
    }

    /// The profile's display name, for the status bar and the sheets.
    var profileName: String {
        guard let name = rz_doc_profile_name(ptr) else { return "" }
        defer { rz_string_free(name) }
        return String(cString: name)
    }

    /// True when the core can convert this document to another space. False
    /// for a LUT-based profile, which is kept and re-embedded all the same —
    /// only Convert to Profile refuses.
    var profileIsConvertible: Bool { rz_doc_profile_is_convertible(ptr) }

    /// The CIE L*a*b* of one straight RGB triple of THIS document's pixels,
    /// read through the document's own profile against the D50 PCS white.
    /// The same bytes therefore read differently in an sRGB and a Display P3
    /// document, which is the point — a sampled colour is already in the
    /// document's space and converts nowhere (ColorProfile.swift's rule).
    /// nil for a profile the core cannot model (a LUT profile), where the
    /// readout must say so rather than assume sRGB.
    func lab(r: UInt8, g: UInt8, b: UInt8) -> (l: Double, a: Double, b: Double)? {
        var out = [Float](repeating: 0, count: 3)
        let ok = out.withUnsafeMutableBufferPointer { lab in
            rz_doc_lab(ptr, r, g, b, lab.baseAddress)
        }
        return ok ? (Double(out[0]), Double(out[1]), Double(out[2])) : nil
    }

    /// The print resolution in pixels per inch, per axis. Pixels never
    /// change with it — only the print size does.
    var resolution: (x: Double, y: Double) {
        (Double(rz_doc_resolution_x(ptr)), Double(rz_doc_resolution_y(ptr)))
    }

    /// One preserved metadata packet, verbatim, or nil when the document
    /// carries none of that kind.
    func metadata(_ kind: RzMetadataKind) -> Data? {
        RasterDocument.readBlob({ rz_doc_metadata_len(ptr, kind) }) { base, len in
            rz_doc_metadata(ptr, kind, base, len)
        }
    }

    /// REINTERPRETS the document in `bytes`: pixels unchanged, profile
    /// replaced. nil — a refusal, not an error — for bytes that are not an
    /// RGB ICC profile, a payload over 16 MiB, or the profile the document
    /// already carries. Ask `RasterProfile.inspect` first to say why.
    func assigningProfile(_ bytes: Data) -> RasterDocument? {
        bytes.withUnsafeBytes { raw in
            wrap(rz_doc_assign_profile(ptr, raw.bindMemory(to: UInt8.self).baseAddress, raw.count))
        }
    }

    /// TRANSFORMS every layer's pixels into `bytes` and replaces the
    /// profile, so the picture looks the same and its numbers change. nil
    /// additionally when either profile is not a matrix/TRC one or the two
    /// describe the same space.
    func convertingToProfile(_ bytes: Data) -> RasterDocument? {
        bytes.withUnsafeBytes { raw in
            wrap(
                rz_doc_convert_to_profile(
                    ptr, raw.bindMemory(to: UInt8.self).baseAddress, raw.count))
        }
    }

    /// Brings a freshly opened document into the working space, ONCE. The
    /// outcome is reported even when no document comes back, so a host can
    /// tell "already in the working space" from "kept, could not be
    /// converted from". Skip this for a `.rz`: it carries its own profile.
    func adoptingWorkingSpace(
        _ bytes: Data
    ) -> (document: RasterDocument?, outcome: RasterAdoptOutcome) {
        var raw: Int32 = 0
        let next = bytes.withUnsafeBytes { buffer in
            wrap(
                rz_doc_adopt_working_space(
                    ptr, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &raw))
        }
        return (next, RasterAdoptOutcome(rawValue: raw) ?? .unchanged)
    }

    /// Stores one metadata packet verbatim, or CLEARS it with nil. Refuses a
    /// payload over 16 MiB and a value the document already carries.
    func settingMetadata(_ kind: RzMetadataKind, _ bytes: Data?) -> RasterDocument? {
        guard let bytes = bytes else { return wrap(rz_doc_set_metadata(ptr, kind, nil, 0)) }
        return bytes.withUnsafeBytes { raw in
            wrap(
                rz_doc_set_metadata(
                    ptr, kind, raw.bindMemory(to: UInt8.self).baseAddress, raw.count))
        }
    }

    /// Sets the print resolution. nil on a non-finite or non-positive
    /// component, or when nothing changes after sanitizing (clamped to
    /// [1, 30000] and quantized to four decimals like the global light, so a
    /// reported value echoed back registers no edit).
    func settingResolution(x: Double, y: Double) -> RasterDocument? {
        guard x.isFinite, y.isFinite else { return nil }
        return wrap(rz_doc_set_resolution(ptr, Float(x), Float(y)))
    }

    /// Writes the document as a flat image with its colour profile and its
    /// metadata packets, format permitting, and reports what was actually
    /// carried.
    ///
    /// `flattened` is THIS document's warm composite (the host's
    /// `projection`); nil makes the core flatten, which re-composites the
    /// whole layer stack. Passing an unrelated image is a caller bug — the
    /// canvas dimensions are not re-checked.
    func saveImage(
        _ flattened: RasterImage?, to url: URL, format: RzFormat, jpegQuality: Int,
        embedProfile: Bool, stripMetadata: Bool
    ) throws -> RasterSaveReport {
        var err: UnsafeMutablePointer<CChar>? = nil
        var carried: UInt32 = 0
        let quality = UInt8(min(max(jpegQuality, 1), 100))
        guard
            rz_doc_save_image(
                ptr, flattened?.ptr, url.path, format, quality, embedProfile, stripMetadata,
                &carried, &err)
        else {
            throw RasterCoreError(
                message: takeErrorMessage(err, fallback: "Could not save \(url.lastPathComponent)."))
        }
        return RasterSaveReport(carried: carried)
    }
}

// MARK: - Colour profiles as values

/// One of the two profiles this build writes for itself.
enum RasterBuiltinProfile: Int32 {
    case sRGB = 0
    case displayP3 = 1

    var rz: RzBuiltinProfile { self == .sRGB ? RZ_PROFILE_SRGB : RZ_PROFILE_DISPLAY_P3 }
}

/// What raw bytes turn out to be. Each case drives different copy and a
/// different set of enabled commands, which is why the core answers five
/// ways rather than "a profile or an error".
enum RasterProfileKind: Int32 {
    /// Not an ICC profile at all — refused, never stored.
    case notICC = 0
    /// An ICC profile whose space is not RGB (Gray, CMYK, Lab) — refused.
    case notRGB = 1
    /// An RGB profile the core cannot convert with (a LUT-based one). It IS
    /// stored: pixels are untouched, display is correct and an export
    /// re-embeds it; only Convert to Profile refuses.
    case rgbUnconvertible = 2
    /// An RGB matrix/TRC profile: full function.
    case rgbMatrix = 3
    /// RGB numbers in a profile whose CLASS is a device link, an abstract
    /// transform or a named-colour list (macOS's own `WebSafeColors.icc`) —
    /// refused. It describes a transform, not the space a picture's numbers
    /// live in, and CoreGraphics cannot convert OUT of one, so a document
    /// tagged with it drew as an empty image everywhere.
    case notImageProfile = 4

    /// True for the two the core will store on a document.
    var isStorable: Bool { self == .rgbUnconvertible || self == .rgbMatrix }
}

/// What an open did to a document's colour. Describes THE OPEN and is not
/// updated by a later Assign or Convert.
enum RasterAdoptOutcome: Int32 {
    case unchanged = 0
    case converted = 1
    case keptUnconvertible = 2
}

/// What raw profile bytes are, and what to call them.
struct RasterProfileInfo {
    let kind: RasterProfileKind
    /// Empty only for `notICC`, which has no profile to name.
    let name: String
}

/// Which of the profile, the packets and the resolution a save actually
/// wrote — the core's answer, not a guess.
struct RasterSaveReport {
    let carried: UInt32

    func carries(_ bit: UInt32) -> Bool { carried & bit != 0 }
}

/// The profile surface that needs no document: the built-in blobs, the
/// five-way inspection a refusal is explained with, and the per-format
/// capability table.
enum RasterProfile {
    /// The bytes of one of the two profiles this build writes. Identical on
    /// every call and every run.
    static func builtin(_ which: RasterBuiltinProfile) -> Data {
        let len = rz_builtin_profile_len(which.rz)
        guard len > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: len)
        let ok = bytes.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return rz_builtin_profile(which.rz, base, len)
        }
        return ok ? Data(bytes) : Data()
    }

    /// Classifies raw bytes and names them. Ask this BEFORE assigning, so a
    /// refusal can say why instead of just beeping.
    static func inspect(_ bytes: Data) -> RasterProfileInfo {
        var name: UnsafeMutablePointer<CChar>? = nil
        let raw = bytes.withUnsafeBytes { buffer in
            rz_icc_inspect(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &name)
        }
        defer { if let name = name { rz_string_free(name) } }
        return RasterProfileInfo(
            kind: RasterProfileKind(rawValue: raw) ?? .notICC,
            name: name.map { String(cString: $0) } ?? "")
    }

    /// True when two profiles describe the SAME colour space — the question
    /// Convert refuses on, asked so a sheet can disable Apply instead of
    /// letting the user discover the refusal as a beep.
    ///
    /// NOT byte equality, which is a different and much narrower question:
    /// the "sRGB IEC61966-2.1" blob most cameras and Photoshop embed is
    /// 3144 bytes against the built-in's 2568 and describes one space. False
    /// when either side is not an RGB profile or is a LUT-based one —
    /// separate refusals, which `inspect` names.
    static func describesSameSpace(_ a: Data, _ b: Data) -> Bool {
        a.withUnsafeBytes { first in
            b.withUnsafeBytes { second in
                rz_icc_describes_same_space(
                    first.bindMemory(to: UInt8.self).baseAddress, first.count,
                    second.bindMemory(to: UInt8.self).baseAddress, second.count)
            }
        }
    }

    /// Which `RZ_CARRIES_*` bits `format` is able to write, so the UI can
    /// disable a checkbox for a reason rather than silently dropping data.
    static func carried(by format: RzFormat) -> UInt32 { rz_format_carries(format) }
}

extension RasterImage {
    /// One plane of THIS image (`width * height` bytes, row 0 = top) — the
    /// ONE plane reader. Exact for the opaque grayscale images the
    /// plane-image getters return, which is what makes `.luma` the
    /// definition of "take the result's gray". nil for `RZ_PLANE_MASK`.
    func plane(_ plane: RzPlane) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: width * height)
        let ok = out.withUnsafeMutableBufferPointer { buffer in
            rz_image_plane(ptr, plane, buffer.baseAddress, UInt32(width), UInt32(height))
        }
        return ok ? out : nil
    }

    /// Shorthand for `plane(RZ_PLANE_LUMA)` — how an op's result comes back
    /// as a plane.
    func lumaPlane() -> [UInt8]? { plane(RZ_PLANE_LUMA) }

    /// One plane of THIS image as an opaque grayscale image — the DISPLAY
    /// reader, run on the cached projection (`ImageDocument.projection`) so a
    /// panel row or a canvas redraw never re-flattens. `maxSide` 0 means full
    /// size.
    func planeImage(_ plane: RzPlane, maxSide: Int) -> RasterImage? {
        guard maxSide >= 0 else { return nil }
        return wrap(rz_image_plane_image(ptr, plane, UInt32(maxSide)))
    }
}

/// Plane arithmetic on caller-owned buffers — the ONE function behind Apply
/// Image and Calculations. Mirrors `RasterSelection`'s shape: planes cross
/// the FFI as raw canvas-sized u8 buffers, not handles.
enum RasterPlaneMath {
    /// `base` blended with `source` IN PLACE:
    /// `base = lerp(base, blend(base, source), opacity)` per pixel, through
    /// the same blend table the projection uses. `invertBase`/`invertSource`
    /// invert an operand FIRST, so the complement is both blended and lerped
    /// from. false on a length mismatch, a non-finite opacity, or one of the
    /// four HSL modes (`RzBlendMode.grayDegenerateModes`), which say nothing
    /// about a single gray plane — blend three planes as one colour with
    /// `blendRGB` for those.
    static func blend(
        _ base: inout [UInt8], with source: [UInt8], width: Int, height: Int,
        mode: RzBlendMode, opacity: Double, invertBase: Bool, invertSource: Bool
    ) -> Bool {
        guard width > 0, height > 0, base.count == width * height,
              source.count == width * height
        else { return false }
        return base.withUnsafeMutableBufferPointer { b in
            source.withUnsafeBufferPointer { s in
                rz_blend_planes(
                    b.baseAddress, s.baseAddress, UInt32(width), UInt32(height),
                    mode, Float(opacity), invertBase, invertSource)
            }
        }
    }

    /// Red, green and blue blended AS ONE COLOUR, in place on the three base
    /// planes — Apply Image with an RGB source onto an RGB target. Same rules
    /// as `blend`, and the one form in which the four HSL modes mean anything
    /// (blending the planes independently would hand each of them a gray
    /// triple, which is what made three of the four the identity). false on a
    /// length mismatch or a non-finite opacity.
    /// The three planes are separate `inout` parameters rather than one array
    /// of three: `base[0].withUnsafeMutableBufferPointer { base[1]… }` would
    /// be overlapping access to the same array, which Swift's exclusivity
    /// checking traps on.
    // Six buffers is what "blend a colour" costs at this boundary; bundling
    // them into a struct would only move the count, and the C declaration
    // spells the same six out.
    static func blendRGB(
        red: inout [UInt8], green: inout [UInt8], blue: inout [UInt8],
        withRed sourceRed: [UInt8], green sourceGreen: [UInt8], blue sourceBlue: [UInt8],
        width: Int, height: Int, mode: RzBlendMode, opacity: Double,
        invertBase: Bool, invertSource: Bool
    ) -> Bool {
        let count = width * height
        guard width > 0, height > 0,
              red.count == count, green.count == count, blue.count == count,
              sourceRed.count == count, sourceGreen.count == count, sourceBlue.count == count
        else { return false }
        // Six nested pointer scopes rather than a flattened interleave: the
        // core takes the three planes as they already are, so nothing is
        // copied on either side of the boundary.
        return red.withUnsafeMutableBufferPointer { r in
            green.withUnsafeMutableBufferPointer { g in
                blue.withUnsafeMutableBufferPointer { b in
                    sourceRed.withUnsafeBufferPointer { sr in
                        sourceGreen.withUnsafeBufferPointer { sg in
                            sourceBlue.withUnsafeBufferPointer { sb in
                                rz_blend_planes_rgb(
                                    r.baseAddress, g.baseAddress, b.baseAddress,
                                    sr.baseAddress, sg.baseAddress, sb.baseAddress,
                                    UInt32(width), UInt32(height), mode, Float(opacity),
                                    invertBase, invertSource)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Selection-mask operations. Unlike images and documents, selection masks
/// cross the FFI as raw canvas-sized u8 coverage buffers (row 0 = top),
/// not handles.
enum RasterSelection {
    /// Gaussian-feathers a coverage mask in place. Sampling clamps to the
    /// canvas edges, so a selection touching the border keeps full
    /// coverage there; radius <= 0 leaves the mask untouched. false on a
    /// size mismatch or a non-finite radius.
    static func featherMask(
        _ mask: inout [UInt8], width: Int, height: Int, radius: Double
    ) -> Bool {
        guard width > 0, height > 0, mask.count == width * height else { return false }
        return mask.withUnsafeMutableBufferPointer { buffer in
            rz_selection_feather(
                buffer.baseAddress, UInt32(width), UInt32(height), Float(radius))
        }
    }

    // Morphology companions to featherMask, same conventions throughout:
    // in place, canvas edges are not contours, a parameter <= 0 leaves the
    // mask untouched, false on a size mismatch or a non-finite parameter.

    /// Grows (dilates) the coverage mask in place by `radius` px of true
    /// Euclidean distance from its 50% contour, re-antialiasing the new
    /// edge.
    static func growMask(
        _ mask: inout [UInt8], width: Int, height: Int, radius: Double
    ) -> Bool {
        guard width > 0, height > 0, mask.count == width * height else { return false }
        return mask.withUnsafeMutableBufferPointer { buffer in
            rz_selection_grow(
                buffer.baseAddress, UInt32(width), UInt32(height), Float(radius))
        }
    }

    /// Shrinks (erodes) the coverage mask in place by `radius` px — grow
    /// with the sign flipped, so edges move inward.
    static func shrinkMask(
        _ mask: inout [UInt8], width: Int, height: Int, radius: Double
    ) -> Bool {
        guard width > 0, height > 0, mask.count == width * height else { return false }
        return mask.withUnsafeMutableBufferPointer { buffer in
            rz_selection_shrink(
                buffer.baseAddress, UInt32(width), UInt32(height), Float(radius))
        }
    }

    /// Replaces the coverage mask in place with an anti-aliased band
    /// `widthPx` wide straddling its 50% contour.
    static func borderMask(
        _ mask: inout [UInt8], width: Int, height: Int, widthPx: Double
    ) -> Bool {
        guard width > 0, height > 0, mask.count == width * height else { return false }
        return mask.withUnsafeMutableBufferPointer { buffer in
            rz_selection_border(
                buffer.baseAddress, UInt32(width), UInt32(height), Float(widthPx))
        }
    }

    /// Smooths the coverage mask in place: featherMask's Gaussian blur
    /// followed by a smoothstep remap, so corners round and jagged edges
    /// reconcile while soft coverage stays soft.
    static func smoothMask(
        _ mask: inout [UInt8], width: Int, height: Int, radius: Double
    ) -> Bool {
        guard width > 0, height > 0, mask.count == width * height else { return false }
        return mask.withUnsafeMutableBufferPointer { buffer in
            rz_selection_smooth(
                buffer.baseAddress, UInt32(width), UInt32(height), Float(radius))
        }
    }
}

/// The formats the app can export/write, bridging display name, RzFormat,
/// UTType, and file extension.
enum ExportFormat: CaseIterable {
    case png
    case jpeg
    case tiff
    case bmp
    case gif
    case webp

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .bmp: return "BMP"
        case .gif: return "GIF"
        case .webp: return "WebP (lossless)"
        }
    }

    var rzFormat: RzFormat {
        switch self {
        case .png: return RZ_FORMAT_PNG
        case .jpeg: return RZ_FORMAT_JPEG
        case .tiff: return RZ_FORMAT_TIFF
        case .bmp: return RZ_FORMAT_BMP
        case .gif: return RZ_FORMAT_GIF
        case .webp: return RZ_FORMAT_WEBP
        }
    }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .gif: return .gif
        case .webp: return .webP
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .bmp: return "bmp"
        case .gif: return "gif"
        case .webp: return "webp"
        }
    }

    static func from(utType: UTType) -> ExportFormat? {
        allCases.first { $0.utType == utType }
    }

    static func from(fileType typeName: String) -> ExportFormat? {
        guard let type = UTType(typeName) else { return nil }
        if let exact = from(utType: type) { return exact }
        return allCases.first { type.conforms(to: $0.utType) }
    }
}

extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int {
        Swift.min(Swift.max(self, low), high)
    }
}

// MARK: - Cube LUTs

/// The `.cube` lookup-table parser — a free function, because parsing a file
/// owns no handle: it produces the params object a `color_lookup` adjustment
/// stores, which the caller then hands to `add_adjustment_layer` or to
/// `applyingAdjustment`.
enum RasterLUT {
    /// The params object parsed from the Adobe Cube LUT at `path`, or the
    /// core's message (`RasterCoreError.message`, since Swift's `Result`
    /// needs a failure type that conforms to `Error` and this file already
    /// has exactly one). A table larger than the core stores is resampled
    /// down and `source_size` reports the size the FILE declared, so a host
    /// can say "resampled from 64". The core never panics on a malformed
    /// file — every failure comes back as a message naming the path.
    static func parseCube(path: String) -> Result<[String: Any], RasterCoreError> {
        var err: UnsafeMutablePointer<CChar>? = nil
        guard let json = rz_lut_parse_cube(path, &err) else {
            return .failure(RasterCoreError(
                message: takeErrorMessage(err, fallback: "Could not read the LUT.")))
        }
        defer { rz_string_free(json) }
        let text = String(cString: json)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let params = object as? [String: Any]
        else {
            return .failure(RasterCoreError(
                message: "The LUT parsed but its parameters could not be read."))
        }
        return .success(params)
    }
}
