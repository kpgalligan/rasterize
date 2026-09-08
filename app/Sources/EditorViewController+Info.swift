import AppKit

/// The Info tab's entry points and the live cursor readout that feeds it.
extension EditorViewController {
    /// View > Info (also the other panels' Info tab).
    @objc func showInfo(_ sender: Any?) {
        layersPanelVisible = true
        showInfoTab()
    }

    func showInfoTab() {
        panelTab = 3
        // The panel PULLS the selection when it starts a background scan:
        // it needs the struct (not the bounds) to build the mask its
        // histogram is gated by, and it must take it on the main thread.
        // Installed here because this is the only path that makes the tab
        // visible, and a hidden panel never scans.
        infoPanel?.selectionProvider = { [weak self] in self?.canvas.selection }
        updatePanelVisibility()
        seedInfoReadout()
    }

    /// The exact number of selected pixels for the Info panel's Area row,
    /// or nil when the editor cannot answer for free — the panel then
    /// measures it on its own background queue, in the same pass that
    /// builds the mask its histogram is gated by, so one canvas scan per
    /// completed gesture buys both answers and the main thread pays for
    /// neither.
    ///
    /// "Free" means the shape's coverage IS its bounds: a pixel-aligned
    /// rectangle (Select All, a snapped marquee) is 255 inside and 0
    /// outside, so width × height is exactly the count under the >= 128
    /// rule everything else in the app measures coverage by. An ellipse, a
    /// lasso polygon or a wand mask is not, and a bounding-box estimate
    /// would overstate an ellipse by a fifth.
    func selectedPixelArea() -> Int? {
        guard let selection = canvas.selection else { return nil }
        if selection.isFullCanvas {
            return selection.canvasWidth * selection.canvasHeight
        }
        guard case .rect(let rect) = selection.shape, rect == rect.integral else { return nil }
        let bounds = selection.bounds
        return Int(bounds.width) * Int(bounds.height)
    }

    /// Every cursor move over the canvas, in image pixels — pure reporting,
    /// so nothing here touches `needsDisplay`.
    ///
    /// nil means the cursor LEFT the canvas, and the readout deliberately
    /// keeps its last value rather than blanking: the reason to look at the
    /// panel is often the pixel you have just moved away from.
    func cursorMoved(to point: CGPoint?) {
        // The ruler marks track the pointer whether or not the Info tab is
        // open, so this goes ABOVE the early-out below. Each strip dirties
        // only its mark's own two rectangles and never the canvas, which is
        // what onCursorMove's contract requires.
        rulerCursorMoved(point)
        // Only the visible Info tab reads pixels; every other tab pays
        // nothing for mouse tracking.
        guard layersPanelVisible, panelTab == 3, let infoPanel = infoPanel else { return }
        guard let point = point, let document = document else { return }
        let pixel = (x: Int(floor(point.x)), y: Int(floor(point.y)))
        // Coalesce on the pixel, not the point: a mouse-moved stream inside
        // one pixel at 800 % zoom would otherwise re-sample the composite
        // dozens of times for the same answer.
        if let last = lastCursorPixel, last.x == pixel.x, last.y == pixel.y { return }
        lastCursorPixel = pixel
        // reach 0 — THE pixel under the cursor, not a neighbourhood mean.
        // The eyedropper's sample size is a paint-picking convenience; a
        // readout that quietly averaged a 5×5 block would report a colour
        // no pixel of the document actually holds.
        infoPanel.setCursor(PixelReadout.at(pixel, in: document, reach: 0))
    }

    /// Reads the pixel the pointer is ALREADY over when the Info tab opens,
    /// so the panel does not sit on em dashes until the mouse happens to
    /// move. Silent when the pointer is anywhere but over the canvas.
    private func seedInfoReadout() {
        guard layersPanelVisible, panelTab == 3, infoPanel != nil else { return }
        guard let window = view.window else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = canvas.convert(inWindow, from: nil)
        // `visibleRect`, not `bounds`: at any zoom past fit the canvas view
        // extends well beyond its clip view, so a pointer resting over the
        // panel maps to a canvas point the user cannot even see.
        guard canvas.visibleRect.contains(point) else { return }
        // The seed must not be swallowed by the coalescing key: opening the
        // tab a second time over the same pixel still has a readout to fill.
        lastCursorPixel = nil
        cursorMoved(to: point)
    }
}
