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
