import AppKit

extension Notification.Name {
    /// Posted (object nil) whenever this phase's app-wide view preferences
    /// change — rulers, ruler unit, guides, the guide lock and colour, the
    /// grid, the pixel grid, the snap toggles.
    ///
    /// They live in `ToolOptionsStore`, which is deliberately shared across
    /// windows ("tool options follow the user, not the document"), so the
    /// window that ran the command is NOT the only one that displays them:
    /// every open editor answers this with `applyViewChrome()`, exactly as
    /// each answers `.imageDocumentImageDidChange` for its own document.
    /// Without it a second window kept its old rulers, guides, grid and
    /// guide colour while its menu showed the new state — and read a stale
    /// `canvas.chrome` when hit-testing a locked guide.
    static let editorViewChromeDidChange = Notification.Name("EditorViewChromeDidChange")
}

/// The ruler strips' layout and refresh, and every View-menu item this phase
/// adds that is a pure PREFERENCE write.
///
/// The two items that edit the DOCUMENT — New Guide… and Clear Guides — live
/// in `EditorViewController+Guides.swift` beside the drags that share their
/// edit path; everything here writes `ToolOptionsStore` and redraws.
///
/// THE RULER ORIGIN MOVES LABELS ONLY. It is document state (it rides every
/// geometry op and lives in `.rz`), but its whole effect is the number a
/// ruler prints and the number the New Guide sheet seeds with. The grid —
/// drawn and snapped — is anchored at canvas (0, 0), and no snap target and
/// no MCP coordinate is measured from the origin.
extension EditorViewController {
    // MARK: - What the strips are measuring

    /// The unit BOTH strips label in and the grid's spacing is authored in.
    var rulerUnit: CanvasUnit {
        CanvasUnit(rawValue: ToolOptionsStore.shared.view.rulerUnitIndex) ?? .pixels
    }

    /// The document's print resolution, sanitized PER AXIS.
    /// `PrintSize.sane` — the ONE sanitizer on this side, and the mirror of
    /// the core's `Resolution::sane` — takes a SCALAR while `resolution` is
    /// a tuple, so it is called twice: a document really can be anisotropic,
    /// and a quarter turn swaps the two.
    var rulerPPI: (x: Double, y: Double) {
        guard let doc = document?.doc else { return (72, 72) }
        return (x: PrintSize.sane(doc.resolution.x), y: PrintSize.sane(doc.resolution.y))
    }

    /// The canvas size the percent unit is a percentage OF.
    var rulerCanvasSize: CGSize {
        document?.doc?.canvasSize ?? CGSize(width: 1, height: 1)
    }

    // MARK: - Layout

    /// Builds the two strips and the corner box into the editor's root view,
    /// wires their gestures and creates the two constraint pairs the
    /// visibility toggle swaps.
    ///
    /// Called with ONE line from `loadView`, which owns nothing else about
    /// the rulers: the frozen file keeps the wiring, this file keeps the
    /// layout. The scroll view's own top and leading constraints are created
    /// HERE rather than in `loadView`'s activation block, because they are
    /// exactly the two edges that move when the rulers appear — the
    /// `scrollTrailingToRoot` / `scrollTrailingToPanel` pair is the template.
    func installRulers(in root: NSView) {
        for strip in [hRuler, vRuler] {
            strip.translatesAutoresizingMaskIntoConstraints = false
            strip.canvas = canvas
        }
        rulerCorner.translatesAutoresizingMaskIntoConstraints = false
        rulerCorner.canvas = canvas
        root.addSubview(rulerCorner)
        root.addSubview(hRuler)
        root.addSubview(vRuler)

        NSLayoutConstraint.activate([
            rulerCorner.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor),
            rulerCorner.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            rulerCorner.widthAnchor.constraint(equalToConstant: DS.rulerThickness),
            rulerCorner.heightAnchor.constraint(equalToConstant: DS.rulerThickness),

            hRuler.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            hRuler.leadingAnchor.constraint(equalTo: rulerCorner.trailingAnchor),
            // The well's trailing edge swaps with the panel, and the strip
            // follows it for free.
            hRuler.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            hRuler.heightAnchor.constraint(equalToConstant: DS.rulerThickness),

            vRuler.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor),
            vRuler.topAnchor.constraint(equalTo: rulerCorner.bottomAnchor),
            vRuler.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            vRuler.widthAnchor.constraint(equalToConstant: DS.rulerThickness),
        ])

        scrollTopToOptions = scrollView.topAnchor.constraint(equalTo: optionsBar.bottomAnchor)
        scrollTopToHRuler = scrollView.topAnchor.constraint(equalTo: hRuler.bottomAnchor)
        scrollLeadingToRail = scrollView.leadingAnchor.constraint(
            equalTo: toolRail.trailingAnchor)
        scrollLeadingToVRuler = scrollView.leadingAnchor.constraint(
            equalTo: vRuler.trailingAnchor)

        // A drag out of the top strip creates a HORIZONTAL guide and out of
        // the side strip a vertical one; AppKit delivers the rest of the
        // drag to the strip that took the press, so the strip forwards the
        // ticks and the release too.
        for strip in [hRuler, vRuler] {
            strip.onDragOut = { [weak self] orientation, point in
                self?.rulerDragOut(orientation, at: point)
            }
            strip.onDragUpdate = { [weak self] point, modifiers in
                self?.guideMouseDragged(point, modifiers)
            }
            strip.onDragEnd = { [weak self] in self?.guideMouseUp() }
        }
        rulerCorner.onOriginDrag = { [weak self] point, committing in
            self?.rulerOriginDrag(to: point, committing: committing)
        }
        rulerCorner.onReset = { [weak self] in self?.resetRulerOrigin() }

        updateRulerVisibility()
    }

    /// Shows or hides the strips, swapping the two constraint pairs — the
    /// `updatePanelVisibility` template.
    func updateRulerVisibility() {
        let visible = ToolOptionsStore.shared.view.rulers
        hRuler.isHidden = !visible
        vRuler.isHidden = !visible
        rulerCorner.isHidden = !visible
        scrollTopToOptions.isActive = false
        scrollTopToHRuler.isActive = false
        scrollLeadingToRail.isActive = false
        scrollLeadingToVRuler.isActive = false
        (visible ? scrollTopToHRuler : scrollTopToOptions).isActive = true
        (visible ? scrollLeadingToVRuler : scrollLeadingToRail).isActive = true
        refreshRulers()
    }

    /// Pushes the unit, the origin and the per-axis pixels-per-unit into both
    /// strips and marks them for display IF anything they draw moved. Called
    /// on every zoom, scroll, document change and preference change —
    /// everything that can move a tick.
    ///
    /// Every invalidation here is guarded on a value: the three assignments
    /// through their own `didSet`s, and the canvas→strip mapping — which
    /// moves under zoom, scroll and a canvas resize with no stored value
    /// changing — through `refreshForMapping()`. `imageDidChange` calls this
    /// for every posting, LIVE ticks included, so an unconditional
    /// `needsDisplay` here repainted both tick ladders and re-laid every
    /// CoreText label on every mouse-moved event of a paint stroke.
    func refreshRulers() {
        guard ToolOptionsStore.shared.view.rulers else { return }
        let unit = rulerUnit
        let ppi = rulerPPI
        let size = rulerCanvasSize
        let origin = document?.doc?.rulerOrigin ?? (x: 0, y: 0)
        hRuler.unit = unit
        hRuler.origin = CGFloat(origin.x)
        hRuler.pixelsPerUnit = unit.pixelsPerUnit(axis: .vertical, ppi: ppi, canvas: size)
        vRuler.unit = unit
        vRuler.origin = CGFloat(origin.y)
        vRuler.pixelsPerUnit = unit.pixelsPerUnit(axis: .horizontal, ppi: ppi, canvas: size)
        hRuler.refreshForMapping()
        vRuler.refreshForMapping()
    }

    /// Rebuilds the canvas's chrome from the preferences AND the document,
    /// and pushes it only when it actually changed.
    ///
    /// THE GRID'S SPACING IS THE DOCUMENT'S HALF OF THE CHROME. It is
    /// authored in the ruler's unit and stored in CANVAS PIXELS, converted
    /// through the document's ppi (inches, cm, mm, points) or its canvas
    /// extent (percent) — so a resolution change, an Image Size, a Canvas
    /// Size, a crop or a quarter turn moves it exactly as it moves a ruler's
    /// labels. That is why this sits beside `refreshRulers()` in
    /// `imageDidChange` as well as inside `syncCanvasPaintState()`: built
    /// only from the preference paths, the drawn and snapped grid kept the
    /// old conversion while the rulers relabelled — a 1-inch grid still
    /// 72 px apart on a document just told it is 300 ppi, and a `.grid` snap
    /// landing on lines the ruler contradicts.
    ///
    /// Guarded on the VALUE, exactly as `refreshCanvasGuides` is and for the
    /// same reason: `imageDidChange` fires on every live drag tick, and
    /// `canvas.chrome`'s `didSet` marks the whole canvas for display.
    func refreshCanvasChrome() {
        let chrome = CanvasChromeSettings(
            from: ToolOptionsStore.shared, unit: rulerUnit, ppi: rulerPPI,
            canvas: rulerCanvasSize)
        guard chrome != canvas.chrome else { return }
        canvas.chrome = chrome
    }

    /// The cursor's position on both strips. Hooked from `cursorMoved(to:)`
    /// ABOVE its Info-tab early-out, because the ruler marks must track the
    /// pointer whether or not the Info panel is open; each strip dirties only
    /// the mark's own two rectangles and never the canvas.
    func rulerCursorMoved(_ point: CGPoint?) {
        guard ToolOptionsStore.shared.view.rulers else { return }
        hRuler.setPointer(point.map { $0.x })
        vRuler.setPointer(point.map { $0.y })
    }

    // MARK: - Menu validation

    /// The ONE answer for every menu item this phase adds.
    ///
    /// nil means "not one of mine" and the frozen file's switch decides as
    /// before. The hook sits ABOVE the text/transform/shape-edit session
    /// guard: these toggles change no pixels and are perfectly safe inside
    /// those sessions — Photoshop keeps them live too — while the two items
    /// that EDIT the document answer false there themselves. (Adding them to
    /// `zoomActions` instead would make that set's name a lie.)
    ///
    /// Checkmarks follow `validateLockItem`'s shape for the whole block:
    /// state from the stored value, enabled whenever there is a document,
    /// fixed titles. Photoshop checks View ▸ Rulers rather than retitling
    /// it, and one convention for the block beats two.
    func validateViewChromeItem(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        guard let action = item.action else { return nil }
        let view = ToolOptionsStore.shared.view
        switch action {
        case #selector(toggleRulers(_:)):
            return chromeItem(item, checked: view.rulers)
        case #selector(toggleGuides(_:)):
            return chromeItem(item, checked: view.guides)
        case #selector(toggleLockGuides(_:)):
            return chromeItem(item, checked: view.guidesLocked)
        case #selector(toggleGrid(_:)):
            return chromeItem(item, checked: view.showGrid)
        case #selector(toggleSnap(_:)):
            return chromeItem(item, checked: view.snapEnabled)
        case #selector(setRulerUnit(_:)):
            return chromeItem(item, checked: item.tag == view.rulerUnitIndex)
        case #selector(setGuideColor(_:)):
            return chromeItem(item, checked: item.tag == view.guideColorIndex)
        case #selector(setGridSpacing(_:)):
            let presets = CanvasGrid.spacingPresets
            return chromeItem(
                item,
                checked: presets.indices.contains(item.tag)
                    && abs(presets[item.tag] - view.gridSpacing) < 0.0001)
        case #selector(setGridSubdivisions(_:)):
            let presets = CanvasGrid.subdivisionPresets
            return chromeItem(
                item,
                checked: presets.indices.contains(item.tag)
                    && presets[item.tag] == view.gridSubdivisions)
        case #selector(toggleSnapTarget(_:)):
            let named = SnapTarget.named
            guard named.indices.contains(item.tag) else {
                return chromeItem(item, checked: false)
            }
            let target = named[item.tag].target
            let targets = SnapTarget(rawValue: view.snapTargets)
            // A target whose lines are HIDDEN snaps nothing, by the rule
            // `makeSnapEngine` states beside each gate: a line nobody can see
            // must not move a drag, so it drops the guides when Show Guides
            // is off and the grid when the grid is not drawn. This is where
            // that dependency becomes VISIBLE — check-marked, enabled and
            // silently inert is the one state a menu must not have, and
            // Photoshop stands both items down in it too. Only the two
            // preferences are asked, not `canvas.drawsDocumentGrid`: a
            // transient stand-down (the crop straighten's) is not something
            // to grey a menu item over, and the user cannot act on it.
            let visible = (target != .grid || view.showGrid)
                && (target != .guides || view.guides)
            return chromeItem(item, checked: targets.contains(target)) && visible
        case #selector(snapToAll(_:)):
            return chromeItem(item, checked: SnapTarget(rawValue: view.snapTargets) == .all)
        case #selector(snapToNone(_:)):
            return chromeItem(
                item, checked: SnapTarget(rawValue: view.snapTargets).isEmpty)
        case #selector(newGuide(_:)):
            // The two DOCUMENT-editing items do stand down inside a session,
            // unlike the toggles above: a new guide is an undo step, and an
            // open text/transform/shape-edit session owns the document.
            return !chromeSessionActive
        case #selector(clearGuides(_:)):
            return !chromeSessionActive && (document?.doc?.guideCount ?? 0) > 0
        default:
            return nil
        }
    }

    /// A checkmark from the stored value, enabled whenever there is a
    /// document — a view toggle is never inapplicable, it is only on or off.
    private func chromeItem(_ item: NSValidatedUserInterfaceItem, checked: Bool) -> Bool {
        if let menuItem = item as? NSMenuItem {
            menuItem.state = checked ? .on : .off
        }
        return document?.doc != nil
    }

    /// True while a text session, a shape-edit session or a Free Transform
    /// owns the document.
    ///
    /// Internal, not private: the two menu items validated above and the
    /// three RULER gestures in `EditorViewController+Guides.swift` must ask
    /// the same question, and every guide edit that is not gated on it is a
    /// session `imageDidChange` silently drops.
    var chromeSessionActive: Bool {
        canvas.hasActiveTextSession || isTransforming || shapeEditSession != nil
    }

    // MARK: - The preference actions

    /// View ▸ Rulers (⌃⌘R).
    @objc func toggleRulers(_ sender: Any?) {
        ToolOptionsStore.shared.view.rulers.toggle()
        // No `updateRulerVisibility()` of its own: the broadcast runs it in
        // every window, this one included. A window that relayed out alone
        // was the whole bug — the others kept strips that then stopped
        // refreshing and drew the ladder of an old magnification.
        viewChromeChanged()
    }

    /// View ▸ Ruler Units ▸ — the tag indexes `CanvasUnit.allCases`.
    @objc func setRulerUnit(_ sender: Any?) {
        let units = CanvasUnit.allCases
        let tag = (sender as? NSMenuItem)?.tag ?? -1
        guard units.indices.contains(tag) else {
            NSSound.beep()
            return
        }
        ToolOptionsStore.shared.view.rulerUnitIndex = tag
        viewChromeChanged()
    }

    /// View ▸ Show Guides (⌘;).
    @objc func toggleGuides(_ sender: Any?) {
        ToolOptionsStore.shared.view.guides.toggle()
        viewChromeChanged()
    }

    /// View ▸ Lock Guides (⌥⌘;). The MOUSE only: New Guide…, Clear Guides
    /// and every MCP mutator still work, because the lock exists to stop an
    /// accidental drag, not to freeze the document.
    @objc func toggleLockGuides(_ sender: Any?) {
        ToolOptionsStore.shared.view.guidesLocked.toggle()
        viewChromeChanged()
    }

    /// View ▸ Guide Color ▸ — the tag indexes `GuideColor.allCases`.
    @objc func setGuideColor(_ sender: Any?) {
        let colors = GuideColor.allCases
        let tag = (sender as? NSMenuItem)?.tag ?? -1
        guard colors.indices.contains(tag) else {
            NSSound.beep()
            return
        }
        ToolOptionsStore.shared.view.guideColorIndex = tag
        viewChromeChanged()
    }

    /// View ▸ Show Grid (⌘').
    @objc func toggleGrid(_ sender: Any?) {
        ToolOptionsStore.shared.view.showGrid.toggle()
        viewChromeChanged()
    }

    /// View ▸ Grid Spacing ▸ — presets in the CURRENT ruler unit.
    @objc func setGridSpacing(_ sender: Any?) {
        let presets = CanvasGrid.spacingPresets
        let tag = (sender as? NSMenuItem)?.tag ?? -1
        guard presets.indices.contains(tag) else {
            NSSound.beep()
            return
        }
        ToolOptionsStore.shared.view.gridSpacing = presets[tag]
        viewChromeChanged()
    }

    /// View ▸ Grid Subdivisions ▸.
    @objc func setGridSubdivisions(_ sender: Any?) {
        let presets = CanvasGrid.subdivisionPresets
        let tag = (sender as? NSMenuItem)?.tag ?? -1
        guard presets.indices.contains(tag) else {
            NSSound.beep()
            return
        }
        ToolOptionsStore.shared.view.gridSubdivisions = presets[tag]
        viewChromeChanged()
    }

    /// View ▸ Snap (⇧⌘;) — the master switch, which outranks both per-tool
    /// checkboxes.
    @objc func toggleSnap(_ sender: Any?) {
        ToolOptionsStore.shared.view.snapEnabled.toggle()
        viewChromeChanged()
    }

    /// View ▸ Snap To ▸ — one item per bit, the tag indexing
    /// `SnapTarget.named`, so five toggles cost one selector (the Layer ▸
    /// Lock template).
    @objc func toggleSnapTarget(_ sender: Any?) {
        let named = SnapTarget.named
        let tag = (sender as? NSMenuItem)?.tag ?? -1
        guard named.indices.contains(tag) else {
            NSSound.beep()
            return
        }
        var targets = SnapTarget(rawValue: ToolOptionsStore.shared.view.snapTargets)
        if targets.contains(named[tag].target) {
            targets.remove(named[tag].target)
        } else {
            targets.insert(named[tag].target)
        }
        ToolOptionsStore.shared.view.snapTargets = targets.rawValue
        viewChromeChanged()
    }

    @objc func snapToAll(_ sender: Any?) {
        ToolOptionsStore.shared.view.snapTargets = SnapTarget.all.rawValue
        viewChromeChanged()
    }

    @objc func snapToNone(_ sender: Any?) {
        ToolOptionsStore.shared.view.snapTargets = SnapTarget([]).rawValue
        viewChromeChanged()
    }

    /// The tail every view-chrome write shares — a BROADCAST, not a local
    /// refresh.
    ///
    /// What was just written is app-wide and persisted, so the window that
    /// ran the command is only one of the windows displaying it. Applying it
    /// to `self` alone left every other open editor showing the old rulers,
    /// guides, grid and guide colour, with its own menu check-marked from the
    /// shared store — so toggling there flipped the preference the wrong way
    /// — and left `canGrabGuide` reading a stale `canvas.chrome`, which is
    /// how a LOCKED guide stayed draggable in the window that did not run the
    /// command.
    func viewChromeChanged() {
        NotificationCenter.default.post(name: .editorViewChromeDidChange, object: nil)
    }

    /// One editor's answer to an app-wide chrome change, wherever it was
    /// made. Registered in `viewDidLoad` beside the document observer.
    @objc func viewChromeDidChange(_ note: Notification) {
        applyViewChrome()
    }

    /// Push the preferences into the strips' layout, into the canvas (and so
    /// into the snap engine's `chrome` reads), relabel the rulers, re-read
    /// the options bar (whose Zoom/Hand cluster shows three of these as
    /// checkboxes and would otherwise go stale), and redraw.
    ///
    /// Every step is idempotent and value-guarded, which is what lets this
    /// run in every window on every chrome change — including the one that
    /// made it, so there is exactly one path and no window can be the
    /// exception.
    func applyViewChrome() {
        updateRulerVisibility()
        syncCanvasPaintState()
        refreshRulers()
        optionsBar.refreshValues()
        // A chrome toggle taken from the KEYBOARD moves no pointer, so
        // nothing re-derives the guide's grab cursor — and Show Guides and
        // Lock Guides both change the answer `canGrabGuide` gives for the
        // guide it is resting on. Without this the arrows stay installed
        // over a guide that has just become invisible or locked, and the
        // next press falls through to the tool and drags the layer instead:
        // exactly the promise `updateGuideHoverCursor` exists to keep
        // (ImageCanvasView+Guides.swift). Clearing is enough — the next
        // `mouseMoved` asks the predicate again.
        canvas.clearGuideHoverCursor()
        canvas.needsDisplay = true
    }
}
