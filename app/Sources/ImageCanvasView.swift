import AppKit

/// Editing tools the canvas understands. Mirrors EditorTool; the view
/// controller keeps the two in sync.
enum CanvasTool {
    case select
    case move
    case brush
    case eraser
    case text
}

/// Text view used for in-canvas text sessions: ⌘Return commits the session.
final class CanvasTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter.
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The document view inside the editor's scroll view. Flipped so that view
/// coordinates equal image pixel coordinates at 100% magnification. The
/// view's frame (pixel size in points) is managed by EditorViewController.
final class ImageCanvasView: NSView {
    var image: CGImage? {
        didSet {
            // The overlay lives at the image's pixel size: throw it away on a
            // size change, otherwise clear it — EXCEPT mid-stroke, where the
            // projection updates on every live-edit tick and the overlay is
            // still accumulating the stroke's geometry.
            if let image = image, image.width == overlayWidth, image.height == overlayHeight {
                if !strokeActive { clearOverlay() }
            } else {
                destroyOverlay()
            }
            needsDisplay = true
        }
    }

    /// When non-nil, drawn instead of `image` (live-preview sheets).
    var previewImage: CGImage? {
        didSet { needsDisplay = true }
    }

    /// The active layer's extent in image pixel coordinates, kept current by
    /// the view controller. Paint tools draw its boundary when it differs
    /// from the canvas rect, since paint outside it cannot land.
    var activeLayerRect: CGRect? {
        didSet {
            if activeLayerRect != oldValue { needsDisplay = true }
        }
    }

    /// The active tool. The view controller commits any pending text session
    /// before flipping this; the setter only abandons stroke/drag state.
    var tool: CanvasTool = .select {
        didSet {
            cancelStroke()
            if moveDragOrigin != nil {
                // A tool switch mid-drag must still close the live edit so
                // the drag-so-far becomes one undo step.
                moveDragOrigin = nil
                onMoveEnd?()
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    // Paint parameters, kept current by EditorViewController.
    var brushSize: CGFloat = 24
    var paintColor: NSColor = .black
    var brushOpacity: CGFloat = 1.0
    var textFont: NSFont = .systemFont(ofSize: 48)

    // Brush/eraser stroke pipeline. The overlay accumulates the stroke's
    // geometry; every tick hands the WHOLE overlay to the receiver, which
    // routes it through the document's live-edit machinery so the canvas
    // previews the true projection (stacking, opacity, blend mode, per-layer
    // erase) during the drag.

    /// Fired before a stroke starts; return false to refuse it (hidden
    /// layer) — the canvas beeps and never begins.
    var onStrokeBegin: (() -> Bool)?
    /// Fired after the initial stamp and after every drag tick with the
    /// overlay's canvas-sized premultiplied RGBA8 bytes (top row first).
    var onStrokeUpdate: ((_ data: UnsafePointer<UInt8>, _ mode: RzCompositeMode, _ alpha: Double) -> Void)?
    var onStrokeEnd: ((_ actionName: String) -> Void)?
    /// Fired when an in-progress stroke is abandoned (tool switch, Escape,
    /// window close); the receiver rolls the live edit back.
    var onStrokeCancel: (() -> Void)?

    /// Called once per text-session commit with the overlay's premultiplied
    /// RGBA8 bytes; the receiver routes them through ImageDocument.applyEdit
    /// as a single undo step.
    var onCommitTextOverlay: ((_ data: UnsafePointer<UInt8>, _ mode: RzCompositeMode, _ alpha: Double, _ actionName: String) -> Void)?
    var onToolKey: ((CanvasTool) -> Void)?
    var onBrushSizeKey: ((CGFloat) -> Void)?

    // Move tool: the view only reports gestures; the view controller owns
    // the active layer's offset and the document's live-edit session.
    var onMoveBegin: (() -> Void)?
    var onMoveUpdate: ((_ dx: Int, _ dy: Int) -> Void)?
    var onMoveEnd: (() -> Void)?
    var onMoveNudge: ((_ dx: Int, _ dy: Int) -> Void)?

    /// Current selection in image pixel coordinates; always integral and
    /// clamped to the image bounds.
    private(set) var selectionRect: CGRect?

    var onSelectionChange: ((CGRect?) -> Void)?

    var hasActiveTextSession: Bool { activeTextView != nil }

    private var dragAnchor: CGPoint?

    // Move-drag state: the unclamped image-space point the drag started at.
    private var moveDragOrigin: CGPoint?

    // Stroke state (brush/eraser).
    private var strokeActive = false
    private var strokeLastPoint: CGPoint?

    // Full-image premultiplied overlay accumulating stroke geometry and
    // rendering text commits. Never drawn directly: the projection previews
    // strokes via the live-edit round trip.
    private var overlayData: UnsafeMutableRawPointer?
    private var overlayContext: CGContext?
    private var overlayWidth = 0
    private var overlayHeight = 0

    private var activeTextView: CanvasTextView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Text sessions must never display glyphs the image-sized commit overlay
    // will discard (apps linked against macOS 14+ stop clipping subviews by
    // default).
    override var clipsToBounds: Bool {
        get { true }
        set {}
    }

    deinit {
        overlayContext = nil
        overlayData?.deallocate()
    }

    private static let checkerboardColor: NSColor = {
        let tile = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor(white: 0.84, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 10, height: 10).fill()
            NSRect(x: 10, y: 10, width: 10, height: 10).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()

    private var magnification: CGFloat {
        max(enclosingScrollView?.magnification ?? 1, 0.001)
    }

    // MARK: - Overlay

    /// Lazily creates the overlay buffer + context at the current image pixel
    /// size. The context is flipped so overlay row 0 is the image's top row
    /// and drawing coordinates match the flipped view coordinates.
    private func ensureOverlayContext() -> CGContext? {
        if let context = overlayContext { return context }
        guard let image = image, image.width > 0, image.height > 0 else { return nil }
        let width = image.width
        let height = image.height
        let byteCount = width * height * 4
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<UInt8>.alignment)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: data,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            data.deallocate()
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        overlayData = data
        overlayContext = context
        overlayWidth = width
        overlayHeight = height
        return context
    }

    private func clearOverlay() {
        guard let context = overlayContext else { return }
        context.clear(CGRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight))
    }

    private func destroyOverlay() {
        overlayContext = nil
        overlayData?.deallocate()
        overlayData = nil
        overlayWidth = 0
        overlayHeight = 0
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Checkerboard under the image rect (the view's bounds are exactly
        // the image rect).
        Self.checkerboardColor.setFill()
        bounds.intersection(dirtyRect).fill()

        // Live strokes preview through the projection itself (the live-edit
        // round trip), so the image is always the truth; the overlay is
        // never composited here.
        let context = NSGraphicsContext.current!.cgContext
        if let cgImage = previewImage ?? image {
            drawFlipped(cgImage, in: context)
        }

        // Paint can only land inside the active layer's extent; when that is
        // smaller than the canvas, show the boundary so strokes and text
        // outside it don't silently vanish.
        if tool == .brush || tool == .eraser || tool == .text,
           let layerRect = activeLayerRect,
           layerRect != CGRect(origin: .zero, size: bounds.size) {
            drawActiveLayerBounds(layerRect)
        }

        if let selection = selectionRect {
            drawSelection(selection)
        }

        if let textView = activeTextView {
            drawTextSessionBorder(textView.frame)
        }
    }

    /// Un-flips the context so the CGImage is not drawn upside down, then
    /// draws it over the full image rect.
    private func drawFlipped(_ cgImage: CGImage, in context: CGContext) {
        context.saveGState()
        context.interpolationQuality = magnification >= 1.0 ? .none : .high
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    private func drawSelection(_ selection: CGRect) {
        // Dim everything outside the selection.
        let dimPath = NSBezierPath(rect: bounds)
        dimPath.appendRect(selection)
        dimPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        dimPath.fill()

        // Hairline double stroke: dashed white over black, offset dash phase.
        let scale = magnification
        let lineWidth = 1 / scale
        let dashPattern: [CGFloat] = [4 / scale, 4 / scale]

        let blackPath = NSBezierPath(rect: selection)
        blackPath.lineWidth = lineWidth
        blackPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        NSColor.black.setStroke()
        blackPath.stroke()

        let whitePath = NSBezierPath(rect: selection)
        whitePath.lineWidth = lineWidth
        whitePath.setLineDash(dashPattern, count: dashPattern.count, phase: 4 / scale)
        NSColor.white.setStroke()
        whitePath.stroke()
    }

    /// Subtle dashed outline (selection stroke style, thinner) marking the
    /// active layer's extent for the paint tools.
    private func drawActiveLayerBounds(_ rect: CGRect) {
        let scale = magnification
        let lineWidth = 0.5 / scale
        let dashPattern: [CGFloat] = [4 / scale, 4 / scale]

        let blackPath = NSBezierPath(rect: rect)
        blackPath.lineWidth = lineWidth
        blackPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        NSColor.black.withAlphaComponent(0.6).setStroke()
        blackPath.stroke()

        let whitePath = NSBezierPath(rect: rect)
        whitePath.lineWidth = lineWidth
        whitePath.setLineDash(dashPattern, count: dashPattern.count, phase: 4 / scale)
        NSColor.white.withAlphaComponent(0.6).setStroke()
        whitePath.stroke()
    }

    /// Dashed hairline border (selection style) around the active text
    /// session's frame.
    private func drawTextSessionBorder(_ frame: NSRect) {
        let scale = magnification
        let rect = frame.insetBy(dx: -2, dy: -2)
        let lineWidth = 1 / scale
        let dashPattern: [CGFloat] = [4 / scale, 4 / scale]

        let blackPath = NSBezierPath(rect: rect)
        blackPath.lineWidth = lineWidth
        blackPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        NSColor.black.setStroke()
        blackPath.stroke()

        let whitePath = NSBezierPath(rect: rect)
        whitePath.lineWidth = lineWidth
        whitePath.setLineDash(dashPattern, count: dashPattern.count, phase: 4 / scale)
        NSColor.white.setStroke()
        whitePath.stroke()
    }

    // MARK: - Selection

    func setSelection(_ rect: CGRect?) {
        var clamped: CGRect? = nil
        if let rect = rect {
            let bounded = rect.integral.intersection(CGRect(origin: .zero, size: bounds.size))
            if !bounded.isEmpty, bounded.width >= 1, bounded.height >= 1 {
                clamped = bounded
            }
        }
        selectionRect = clamped
        needsDisplay = true
        onSelectionChange?(clamped)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if hasActiveTextSession {
            commitTextSession()
            // With the text tool, this click only ends the session; the user
            // clicks again to start a new one.
            if tool == .text { return }
        }
        let point = clamp(point: convert(event.locationInWindow, from: nil))
        switch tool {
        case .select:
            dragAnchor = point
        case .move:
            // Unclamped: deltas stay honest when the drag leaves the canvas.
            moveDragOrigin = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.set()
            onMoveBegin?()
        case .brush, .eraser:
            beginStroke(at: point)
        case .text:
            beginTextSession(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        switch tool {
        case .select:
            guard let anchor = dragAnchor else { return }
            setSelection(rect(from: anchor, to: clamp(point: raw)))
        case .move:
            guard let origin = moveDragOrigin else { return }
            NSCursor.closedHand.set()
            onMoveUpdate?(Int((raw.x - origin.x).rounded()), Int((raw.y - origin.y).rounded()))
        case .brush, .eraser:
            // No clamping: the image-sized overlay context clips naturally,
            // so a stroke that leaves the canvas paints up to the edge and
            // stops instead of smearing along the border.
            continueStroke(to: raw)
        case .text:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .select:
            guard let anchor = dragAnchor else { return }
            dragAnchor = nil
            let point = clamp(point: convert(event.locationInWindow, from: nil))
            let dragged = rect(from: anchor, to: point)
            // The click-vs-drag threshold is ~2 SCREEN points; `dragged` is in
            // image pixels, so scale by the current magnification. Otherwise a
            // deliberate 1-px-wide selection is impossible at high zoom, and at
            // low zoom a jittery click commits a many-pixel accidental selection.
            let scale = magnification
            if dragged.width * scale < 2 || dragged.height * scale < 2 {
                // Treat a tiny drag as click-to-deselect.
                setSelection(nil)
            } else {
                setSelection(dragged)
            }
        case .move:
            guard moveDragOrigin != nil else { return }
            moveDragOrigin = nil
            window?.invalidateCursorRects(for: self)
            onMoveEnd?()
        case .brush, .eraser:
            endStroke()
        case .text:
            break
        }
    }

    private func clamp(point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), bounds.width),
            y: min(max(point.y, 0), bounds.height))
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y))
    }

    // MARK: - Brush / eraser strokes

    private func beginStroke(at point: CGPoint) {
        // The begin callback opens the document's live-edit session and may
        // refuse (hidden layer); it must not fire if the overlay is missing.
        guard let context = ensureOverlayContext(), onStrokeBegin?() == true else {
            NSSound.beep()
            return
        }
        context.saveGState()
        if let selection = selectionRect {
            // Strokes and erases confine to the active selection.
            context.clip(to: selection)
        }
        // For the eraser only alpha matters, so an opaque paint color works
        // for both tools.
        let color = (paintColor.usingColorSpace(.sRGB) ?? paintColor).withAlphaComponent(1)
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(brushSize)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        var point = point
        if brushSize <= 1 {
            // Pixel work: snap to the pixel center and defeat antialiasing so
            // a size-1 brush paints (or erases) whole solid pixels instead of
            // a ~78%-alpha fuzzy blob. The flag lives in the gstate saved
            // above and restored when the stroke ends.
            context.setShouldAntialias(false)
            point = CGPoint(
                x: min(floor(point.x), CGFloat(overlayWidth - 1)) + 0.5,
                y: min(floor(point.y), CGFloat(overlayHeight - 1)) + 0.5)
        }
        strokeActive = true
        strokeLastPoint = point
        // Starting dot so a plain click leaves a mark.
        let dot = CGRect(
            x: point.x - brushSize / 2, y: point.y - brushSize / 2,
            width: brushSize, height: brushSize)
        context.fillEllipse(in: dot)
        emitStrokeUpdate()
    }

    private func continueStroke(to point: CGPoint) {
        guard strokeActive, let last = strokeLastPoint, let context = overlayContext else { return }
        var point = point
        if brushSize <= 1 {
            // Same pixel-center snapping as beginStroke; no clamping, so
            // off-canvas points still exit cleanly instead of edge-pinning.
            point = CGPoint(x: floor(point.x) + 0.5, y: floor(point.y) + 0.5)
        }
        context.move(to: last)
        context.addLine(to: point)
        context.strokePath()
        strokeLastPoint = point
        emitStrokeUpdate()
    }

    /// Hands the accumulated overlay to the receiver, which repaints it onto
    /// the pre-stroke document and swaps in the resulting projection (which
    /// is what redraws the canvas — the overlay itself is never drawn).
    private func emitStrokeUpdate() {
        guard let data = overlayData else { return }
        let erasing = tool == .eraser
        onStrokeUpdate?(
            UnsafePointer(data.assumingMemoryBound(to: UInt8.self)),
            erasing ? RZ_COMPOSITE_ERASE : RZ_COMPOSITE_OVER,
            Double(brushOpacity))
    }

    private func endStroke() {
        guard strokeActive else { return }
        overlayContext?.restoreGState()
        strokeActive = false
        strokeLastPoint = nil
        clearOverlay()
        // Always fires once a stroke began: the live-edit session must
        // close even if the whole stroke missed the layer.
        onStrokeEnd?(tool == .eraser ? "Erase" : "Brush Stroke")
    }

    /// Abandons any in-progress stroke without committing (tool switches,
    /// Escape, window close); the receiver rolls the live edit back.
    private func cancelStroke() {
        strokeLastPoint = nil
        guard strokeActive else { return }
        overlayContext?.restoreGState()
        strokeActive = false
        clearOverlay()
        onStrokeCancel?()
        needsDisplay = true
    }

    // MARK: - Text sessions

    private func beginTextSession(at point: CGPoint) {
        // Shift the box left rather than letting the 40px minimum overhang
        // the right edge, where committed glyphs would be clipped away.
        let width = min(600, max(bounds.width - point.x, 40))
        let x = max(0, min(point.x, bounds.width - width))
        let height = textFont.pointSize * 1.5
        let textView = CanvasTextView(
            frame: NSRect(x: x, y: point.y, width: width, height: height))
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = textFont
        textView.textColor = paintColor
        textView.insertionPointColor = paintColor
        textView.minSize = NSSize(width: width, height: height)
        textView.maxSize = NSSize(width: width, height: 10_000_000)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: 10_000_000)
        // Zero padding so the live session lines up with the committed text.
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        textView.onCommandReturn = { [weak self] in self?.commitTextSession() }
        addSubview(textView)
        activeTextView = textView
        needsDisplay = true
        window?.makeFirstResponder(textView)
    }

    /// Applies the current textFont/paintColor to the whole active session
    /// (called by the view controller when the options change).
    func updateActiveTextSessionStyle() {
        guard let textView = activeTextView else { return }
        textView.font = textFont
        textView.textColor = paintColor
        textView.insertionPointColor = paintColor
        if let storage = textView.textStorage, storage.length > 0 {
            let range = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.font, value: textFont, range: range)
            storage.addAttribute(.foregroundColor, value: paintColor, range: range)
        }
        resizeActiveTextSession()
    }

    private func resizeActiveTextSession() {
        guard let textView = activeTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let minHeight = (textView.font ?? textFont).pointSize * 1.5
        let height = max(used.height + textView.textContainerInset.height * 2 + 2, minHeight)
        if abs(textView.frame.height - height) > 0.5 {
            var frame = textView.frame
            frame.size.height = height
            textView.frame = frame
        }
        needsDisplay = true
    }

    /// Renders the session's text into the overlay and commits it as one
    /// undo step. An all-whitespace session cancels instead.
    func commitTextSession() {
        guard let textView = activeTextView else { return }
        let string = textView.string
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelTextSession()
            return
        }
        let sessionFont = textView.font ?? textFont
        let sessionColor = textView.textColor ?? paintColor
        let origin = textView.frame.origin
        let width = textView.frame.width
        removeTextSessionView()

        // A session pushed fully outside the image (e.g. the canvas shrank
        // underneath it) has nothing to contribute; skip the empty undo step.
        guard origin.x < bounds.width, origin.y < bounds.height, origin.x + width > 0 else {
            return
        }

        guard let context = ensureOverlayContext() else {
            NSSound.beep()
            return
        }
        // The overlay is idle between strokes; start from empty regardless.
        clearOverlay()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: sessionFont, .foregroundColor: sessionColor])
        attributed.draw(
            with: NSRect(x: origin.x, y: origin.y, width: width, height: 10_000_000),
            // .usesFontLeading matches NSLayoutManager's live-session line
            // metrics; without it each committed line lands ~1.4px high per
            // line of leading and the block visibly contracts on commit.
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        NSGraphicsContext.restoreGraphicsState()

        if let data = overlayData {
            onCommitTextOverlay?(
                UnsafePointer(data.assumingMemoryBound(to: UInt8.self)),
                RZ_COMPOSITE_OVER, 1.0, "Add Text")
        }
        clearOverlay()
        needsDisplay = true
    }

    /// Removes the session's text view without committing anything.
    func cancelTextSession() {
        removeTextSessionView()
    }

    private func removeTextSessionView() {
        guard let textView = activeTextView else { return }
        activeTextView = nil
        textView.delegate = nil
        textView.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Keyboard and cursor

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // A window closing mid-drag never delivers mouseUp; the live edit
        // must still roll back and close.
        if newWindow == nil {
            cancelStroke()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            if strokeActive {
                // Abandon the in-progress stroke; the live edit rolls back.
                cancelStroke()
                return
            }
            setSelection(nil)
            return
        }
        // Arrow-key nudges for the move tool (Shift: 10px). Down is +y in the
        // flipped image coordinate space.
        if tool == .move, !hasActiveTextSession,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let step = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: onMoveNudge?(-step, 0); return // left
            case 124: onMoveNudge?(step, 0); return // right
            case 125: onMoveNudge?(0, step); return // down
            case 126: onMoveNudge?(0, -step); return // up
            default:
                break
            }
        }
        // Bare tool keys (Photoshop-style), handled here only (never as menu
        // key equivalents — they would steal keystrokes from text editing).
        // The text view is first responder during sessions anyway.
        if !hasActiveTextSession,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let characters = event.charactersIgnoringModifiers?.lowercased() {
            switch characters {
            case "m":
                onToolKey?(.select)
                return
            case "v":
                onToolKey?(.move)
                return
            case "b":
                onToolKey?(.brush)
                return
            case "e":
                onToolKey?(.eraser)
                return
            case "t":
                onToolKey?(.text)
                return
            case "[" where tool == .brush || tool == .eraser:
                onBrushSizeKey?(min(max(brushSize * 0.8, 1), 200))
                return
            case "]" where tool == .brush || tool == .eraser:
                onBrushSizeKey?(min(max(brushSize * 1.25, 1), 200))
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        switch tool {
        case .select, .brush, .eraser:
            addCursorRect(bounds, cursor: .crosshair)
        case .move:
            addCursorRect(bounds, cursor: moveDragOrigin == nil ? .openHand : .closedHand)
        case .text:
            addCursorRect(bounds, cursor: .iBeam)
        }
    }
}

// MARK: - NSTextViewDelegate (text sessions)

extension ImageCanvasView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        resizeActiveTextSession()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextSession()
            return true
        }
        return false
    }
}
