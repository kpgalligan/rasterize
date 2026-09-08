import AppKit

/// Everything the Info panel — and `sample_pixel`, its agent twin — says
/// about one pixel of the flattened composite.
///
/// The colour rule is the app's, applied once here so the panel and the tool
/// cannot disagree: `rgba` and `hex` are the DOCUMENT's own numbers,
/// converted nowhere (a sampled colour is already in the document's space);
/// `hsb` is derived from those same numbers; `lab` goes through the
/// document's OWN profile against the D50 PCS white, so the same bytes read
/// differently in an sRGB and a Display P3 document — and is nil, never a
/// silent sRGB guess, for a profile this build cannot model; and `paintHex`
/// is the closest sRGB spelling for a colour ARGUMENT, with `paintExact`
/// false when the pixel is outside the sRGB gamut.
struct PixelReadout {
    let x: Int
    let y: Int
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
    /// `#RRGGBB` (`#RRGGBBAA` when not fully opaque) of the document's own
    /// numbers.
    let hex: String
    /// Hue in degrees 0…360, saturation and brightness as fractions 0…1 —
    /// the standard hexcone over the document's numbers.
    let hsb: (h: Double, s: Double, b: Double)
    /// CIE L*a*b* through the document's profile, or nil when the core
    /// cannot model that profile.
    let lab: (l: Double, a: Double, b: Double)?
    /// The profile the Lab reading went through, for the row's caption.
    let labSpace: String
    let paintHex: String
    let paintExact: Bool

    /// The readout at one canvas point, averaging the (2·reach+1) square
    /// about it the way the eyedropper does — out-of-bounds pixels dropped,
    /// truncating, and a centre just outside the canvas accepted as long as
    /// part of the square is inside (the core's `rz_image_sample`).
    /// nil when the document has no pixels, or when no pixel of the block
    /// is inside the canvas.
    static func at(_ point: (x: Int, y: Int), in document: ImageDocument, reach: Int)
        -> PixelReadout?
    {
        guard let doc = document.doc,
              let projection = document.projection ?? doc.flattened(),
              let rgba = projection.sample(x: point.x, y: point.y, reach: reach)
        else { return nil }
        let paint = ColorProfile.paintBytes(rgba, in: doc.nsColorSpace)
        return PixelReadout(
            x: point.x, y: point.y,
            r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a,
            hex: RasterImage.hexString(rgba),
            hsb: hsb(rgba.r, rgba.g, rgba.b),
            lab: doc.lab(r: rgba.r, g: rgba.g, b: rgba.b),
            labSpace: doc.profileName,
            paintHex: RasterImage.hexString(
                (r: paint.bytes[0], g: paint.bytes[1], b: paint.bytes[2], a: paint.bytes[3])),
            paintExact: paint.exact)
    }

    /// The standard hexcone, on the document's own numbers — display only,
    /// which is why it lives on this side rather than in the core.
    private static func hsb(_ r: UInt8, _ g: UInt8, _ b: UInt8)
        -> (h: Double, s: Double, b: Double)
    {
        let red = Double(r) / 255, green = Double(g) / 255, blue = Double(b) / 255
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let delta = high - low
        var hue = 0.0
        if delta > 0 {
            if high == red {
                hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if high == green {
                hue = 60 * ((blue - red) / delta + 2)
            } else {
                hue = 60 * ((red - green) / delta + 4)
            }
        }
        if hue < 0 { hue += 360 }
        return (h: hue, s: high == 0 ? 0 : delta / high, b: high)
    }

    /// The panel's and the tool's shared rounding: whole degrees and whole
    /// percents, the way Photoshop's Info panel prints them.
    var hsbRounded: (h: Int, s: Int, b: Int) {
        (
            h: Int(hsb.h.rounded()) % 360,
            s: Int((hsb.s * 100).rounded()),
            b: Int((hsb.b * 100).rounded())
        )
    }
}
