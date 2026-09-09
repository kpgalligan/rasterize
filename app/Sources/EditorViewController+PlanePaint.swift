import AppKit

/// Fill and gradient on a colour plane or an alpha channel: the canvas
/// click paths, redirected when the edit target is a plane. The region
/// grow and the gradient themselves are the existing core ops — the plane
/// becomes a scratch one-layer document, the SAME `bucketFilled` /
/// `gradiented` runs on it, and its luma comes back as the new plane
/// (`ImageDocument.applyPlaneScratchEdit`). No second region-grow, no
/// second gradient.
///
/// A plane holds COVERAGE, not colour, so the tools' colours enter as grays
/// (`planeCoverageBytes`) and the options bar's opacity keeps riding in the
/// colour's alpha exactly as it does on the layer paths.
///
/// The fill's region grow runs over the ACTIVE LAYER's plane — the target
/// of the edit — while the canvas shows the COMPOSITE's plane. They are the
/// same pixels on a single-layer document, which is what this feature is
/// mostly used on; elsewhere the seed's neighbourhood is the layer's, and
/// that is the plane being written.
///
/// The seed, the gradient's endpoints and the selection mask are all CANVAS
/// coordinates; `PlaneScratchOp` maps them into the space the target plane
/// lives in (the layer's own grid for a colour plane), which is what makes
/// a plane fill reach exactly the pixels a whole-layer fill would.
extension EditorViewController {
    /// The fill tool's click while a plane or channel is targeted.
    func fillPlane(at point: CGPoint) {
        guard let document = document, paintTarget.targetsPlaneOrChannel else {
            NSSound.beep()
            return
        }
        let target = paintTarget
        // A colour plane rewrites the layer's PIXELS, so a fill aimed at an
        // adjustment layer's (ignored) pixels is refused with the very
        // alert the whole-layer path shows — a canvas click is outside menu
        // validation's reach. A CHANNEL is document state and is never
        // refused: it has nothing to do with the active layer.
        if target.isPlane, refuseAdjustmentPixelEdit() { return }
        let options = ToolOptionsStore.shared.fill
        // The bar's opacity rides in the fill colour's own alpha, exactly
        // as it does on the layer path.
        let opacity = min(max(options.opacity, 0), 100) / 100
        guard let rgba = planeCoverageBytes(
            paintColor.withAlphaComponent(paintColor.alphaComponent * CGFloat(opacity)))
        else {
            NSSound.beep()
            return
        }
        document.applyPlaneScratchEdit(
            "Fill", target,
            .fill(
                x: Int(point.x), y: Int(point.y), rgba: rgba,
                tolerance: Int(options.tolerance.rounded()), contiguous: options.contiguous),
            mask: canvas.selection?.maskBytes(),
            // The AUTHORED colour, not the gray it becomes: the `fill` tool
            // performs the same coverage conversion for a plane target
            // (`PlaneAlgebra.coverageColor`), so recording the gray would
            // convert it twice.
            record: .fill(
                at: point,
                color: paintColor.withAlphaComponent(
                    paintColor.alphaComponent * CGFloat(opacity)),
                tolerance: Int(options.tolerance.rounded()),
                contiguous: options.contiguous,
                target: target.agentName(in: document.doc)))
    }

    /// The gradient tool's drag while a plane or channel is targeted.
    func gradientPlane(from a: CGPoint, to b: CGPoint) {
        guard let document = document, paintTarget.targetsPlaneOrChannel else {
            NSSound.beep()
            return
        }
        let target = paintTarget
        // Same rule as fillPlane, and for the same reason: a gradient drag
        // ends on the canvas, outside menu validation's reach.
        if target.isPlane, refuseAdjustmentPixelEdit() { return }
        let options = ToolOptionsStore.shared.gradient
        // Foreground → background (the rail's swatches); Reverse swaps them
        // and the bar's opacity rides in both colours' alpha.
        let opacity = CGFloat(min(max(options.opacity, 0), 100) / 100)
        let fade: (NSColor) -> NSColor = { $0.withAlphaComponent($0.alphaComponent * opacity) }
        guard let start = planeCoverageBytes(fade(options.reverse ? backgroundColor : paintColor)),
              let end = planeCoverageBytes(fade(options.reverse ? paintColor : backgroundColor))
        else {
            NSSound.beep()
            return
        }
        let kind: RzGradientKind =
            options.typeIndex == 1 ? RZ_GRADIENT_RADIAL : RZ_GRADIENT_LINEAR
        document.applyPlaneScratchEdit(
            "Gradient", target,
            .gradient(from: a, to: b, start: start, end: end, kind: kind),
            mask: canvas.selection?.maskBytes(),
            // The authored colours, for the reason `fillPlane` gives.
            record: .gradient(
                from: a, to: b,
                start: fade(options.reverse ? backgroundColor : paintColor),
                end: fade(options.reverse ? paintColor : backgroundColor),
                radial: options.typeIndex == 1,
                target: target.agentName(in: document.doc)))
    }

    /// A tool colour as the opaque gray a plane is filled with —
    /// `PlaneAlgebra.coverageColor`, shared with the MCP mirrors, which is
    /// where the rule and its reasoning live.
    private func planeCoverageBytes(_ color: NSColor) -> [UInt8]? {
        PlaneAlgebra.coverageColor(colorBytes(color))
    }
}
