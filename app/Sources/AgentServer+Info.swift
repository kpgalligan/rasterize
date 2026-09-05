import AppKit

/// The two READ-ONLY tools behind the Info panel: the histogram it plots and
/// the readout that follows the cursor. Neither registers an undo step nor
/// dirties the document — they only look.
extension AgentServer {
    /// histogram: the agent mirror of the Info panel's histogram (also the
    /// plot behind Levels and Curves). Always at stride 1 — only the app's
    /// live panel samples, because only it re-scans on every brush tick.
    func histogram(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let sourceName = stringArg(a, "source") ?? "composite"
        let source: HistogramSource
        var reported: [String: Any] = ["source": sourceName]
        switch sourceName {
        case "composite":
            source = .composite
        case "layer":
            let index = try paintLayerIndex(a, document)
            source = .layer(index)
            reported["layer"] = index
        default:
            throw ToolError(
                message: "source must be \"composite\" or \"layer\" (got \"\(sourceName)\")")
        }
        // The selection GATES any source; it is not a fourth one. A pixel
        // inside it counts when its coverage is 128 or more, the same 50 %
        // contour rule the marquee uses everywhere else.
        let gated = boolArg(a, "selection") ?? true
        let mask = gated ? editor(document)?.agentSelection?.maskBytes() : nil
        guard let bins = Histogram.of(document, source: source, selection: mask, stride: 1) else {
            throw ToolError(message: "Could not read the histogram of that source")
        }
        reported["ok"] = true
        reported["selection"] = mask != nil
        reported["total"] = bins.total
        reported["bins"] = [
            "red": bins.red, "green": bins.green, "blue": bins.blue, "luma": bins.luma,
        ]
        reported["clipped"] = [
            "shadows": bins.shadowClipped, "highlights": bins.highlightClipped,
        ]
        reported["note"] =
            "256 bins per channel, 0 = black. Fully transparent pixels are never counted, "
            + "so total (\(bins.total)) is the number of pixels actually measured out of "
            + "\(doc.width * doc.height) on the canvas. clipped.shadows and "
            + "clipped.highlights are the largest per-channel counts in bin 0 and bin 255."
        return try jsonResult(reported)
    }

    /// sample_pixel: the agent mirror of the Info panel's readout —
    /// `sample_color` is the paint-oriented twin, and the two agree about
    /// the pixel's own numbers.
    func samplePixel(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard let x = intArg(a, "x"), let y = intArg(a, "y") else {
            throw ToolError(message: "sample_pixel requires x and y")
        }
        let size = intArg(a, "sample_size") ?? 1
        guard let reach = [1: 0, 3: 1, 5: 2][size] else {
            throw ToolError(message: "sample_size must be 1, 3 or 5 (got \(size))")
        }
        guard let readout = PixelReadout.at((x: x, y: y), in: document, reach: reach) else {
            throw ToolError(
                message: "No part of the \(size)×\(size) sample at (\(x), \(y)) is inside "
                    + "the canvas (\(doc.width)×\(doc.height), origin top-left)")
        }
        let hsb = readout.hsbRounded
        var result: [String: Any] = [
            "ok": true, "x": x, "y": y, "sample_size": size,
            "r": Int(readout.r), "g": Int(readout.g), "b": Int(readout.b),
            "a": Int(readout.a),
            "hex": readout.hex,
            "hsb": ["h": hsb.h, "s": hsb.s, "b": hsb.b],
            "space": doc.profileName,
            "lab_space": readout.labSpace,
            "paint_hex": readout.paintHex,
            "paint_hex_exact": readout.paintExact,
        ]
        var notes: [String] = []
        if let lab = readout.lab {
            result["lab"] = [
                "l": (lab.l * 1000).rounded() / 1000,
                "a": (lab.a * 1000).rounded() / 1000,
                "b": (lab.b * 1000).rounded() / 1000,
            ]
        } else {
            result["lab"] = NSNull()
            notes.append(
                "Lab is null because this build cannot model \(readout.labSpace) (a LUT "
                    + "profile); reporting an sRGB reading instead would be a made-up number.")
        }
        if !readout.paintExact {
            notes.append(
                "This pixel is outside the sRGB gamut, so no sRGB hex names it: painting "
                    + "paint_hex back gives the closest sRGB colour, which is duller than "
                    + "what was sampled.")
        }
        if !notes.isEmpty { result["note"] = notes.joined(separator: " ") }
        return try jsonResult(result)
    }
}
