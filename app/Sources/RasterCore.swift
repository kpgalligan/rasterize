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

    /// Opens the frontmost pasteboard image as a RasterImage. The bitmap is
    /// normalized to PNG and routed through the Rust core via a temp file so
    /// the result behaves exactly like an opened file.
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> RasterImage? {
        guard let pasted = NSImage(pasteboard: pasteboard),
              let tiff = pasted.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rasterize-clipboard-\(ProcessInfo.processInfo.globallyUniqueString).png")
        guard (try? png.write(to: tempURL)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try? RasterImage.open(url: tempURL)
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
    func makeCGImage() -> CGImage? {
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
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent)
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
    static let allBlendModes: [(RzBlendMode, String)] = blendModeGroups.flatMap { $0 }

    /// Display name for a mode (status bar, layer-row meta lines).
    static func displayName(for mode: RzBlendMode) -> String {
        allBlendModes.first { $0.0 == mode }?.1 ?? "Normal"
    }
}

/// Owning Swift wrapper around an `RzDocument *` handle from the Rust core:
/// a canvas size plus a bottom-first layer stack. Handles are immutable;
/// every operation returns a new handle. Handles share unchanged layer pixel
/// buffers (copy-on-write), so clones and per-layer edits are cheap and the
/// undo stack can keep whole-document snapshots.
final class RasterDocument {
    let ptr: OpaquePointer

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

    /// Wraps an image as a single-"Background"-layer document.
    static func from(image: RasterImage) -> RasterDocument? {
        rz_doc_from_image(image.ptr).map { RasterDocument(owning: $0) }
    }

    func clone() -> RasterDocument? { wrap(rz_doc_clone(ptr)) }

    var width: Int { Int(rz_doc_width(ptr)) }
    var height: Int { Int(rz_doc_height(ptr)) }
    var canvasSize: NSSize { NSSize(width: width, height: height) }
    var layerCount: Int { Int(rz_doc_layer_count(ptr)) }

    /// Value snapshot of one layer's metadata (index 0 = bottom layer).
    struct LayerInfo {
        let name: String
        let opacity: Double
        let blendMode: RzBlendMode
        let visible: Bool
        let offsetX: Int
        let offsetY: Int
        let width: Int
        let height: Int
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
            height: Int(rz_doc_layer_height(ptr, i)))
    }

    /// Copy of a layer's pixels at the layer's own size.
    func layerImage(_ idx: Int) -> RasterImage? {
        guard isValidIndex(idx) else { return nil }
        return wrapImage(rz_doc_layer_image(ptr, idx))
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

    func withLayerOffset(_ idx: Int, _ x: Int, _ y: Int) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_offset(ptr, idx, Int32(clamping: x), Int32(clamping: y)))
    }

    /// Replaces a layer's pixels (any size; offset and properties kept).
    func withLayerPixels(_ idx: Int, _ image: RasterImage) -> RasterDocument? {
        guard isValidIndex(idx) else { return nil }
        return wrap(rz_doc_with_layer_pixels(ptr, idx, image.ptr))
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

    /// Writes the native RZDC format (all layers preserved).
    func saveNative(to url: URL) throws {
        var err: UnsafeMutablePointer<CChar>? = nil
        guard rz_doc_save_native(ptr, url.path, &err) else {
            throw RasterCoreError(
                message: takeErrorMessage(err, fallback: "Could not save \(url.lastPathComponent)."))
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
