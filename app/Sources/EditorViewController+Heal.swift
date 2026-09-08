import AppKit

/// The Healing Brush and the Spot Healing Brush: the two seams the canvas
/// hands a healing stroke to, and no other logic.
///
/// Both tools are ONE solve per stroke. The canvas paints the footprint into
/// its overlay while the drag runs — the Healing Brush through the clone
/// pipeline (the sampled pixels, so the drag previews a raw clone), the Spot
/// Healing Brush through the plain dab pipeline (pure coverage, so the drag
/// only ghosts) — and hands the WHOLE footprint here once, at mouse-up,
/// while the live-edit session opened at mouse-down is still open. So the
/// Poisson solve runs once, against the pre-stroke handle, and the drag's
/// preview and the healed result collapse into ONE undo step when
/// `onStrokeEnd` closes the session immediately after this returns. Rolling
/// the preview back here instead makes that close a same-handle no-op: a
/// refused heal leaves no undo step and no pixel changed.
extension EditorViewController {

    /// The image a clone-path stroke stamps from. nil means "the canvas's
    /// own projection", which is the answer for every tool but one:
    ///
    /// - the Clone Stamp always samples the flattened composite;
    /// - the Healing Brush with Sample All Layers ON wants that same
    ///   composite, and the canvas already holds it;
    /// - the Spot Healing Brush never reads a snapshot at all — its overlay
    ///   carries pure coverage and the core generates the source, so its own
    ///   Sample All Layers flag is the core's (§0.4/§0.5). Answering with a
    ///   layer image here would be dead weight at best.
    ///
    /// That leaves the Healing Brush with Sample All Layers OFF, which
    /// stamps the active layer's own pixels.
    func strokeSourceImage() -> CGImage? {
        // `strokeTool` is the tool the stroke BEGAN with (onStrokeBegin
        // latched it a moment ago, before the canvas asked): a tool change
        // mid-drag can never swap the snapshot out from under the stroke.
        guard strokeTool == .heal, !ToolOptionsStore.shared.heal.sampleAllLayers,
            let document = document, let doc = document.doc
        else { return nil }
        // The layer's pixels already placed in canvas space and transparent
        // elsewhere — so a dab over the layer's emptiness deposits alpha 0,
        // which is below the coverage threshold and heals nothing, exactly
        // as sampling nothing should behave. Tagged with the same space the
        // canvas's own projection image wears, so the displaced draw moves
        // the document's numbers unconverted (a sampled colour converts
        // nowhere). An empty layer answers nil and falls back to the
        // composite in the canvas, which is harmless: a layer with no pixels
        // has nothing for the heal to write to either, so the op refuses and
        // the stroke rolls back below.
        return doc.layerCanvasImage(document.activeLayerIndex)?
            .makeCGImage(in: doc.colorSpace)
    }

    /// Solves the healing op over the stroke's whole footprint and replaces
    /// the live-edit preview with the result. `data` is the canvas-sized
    /// premultiplied overlay the stroke rasterized — its alpha is the
    /// footprint's coverage, its RGB the already-aligned source (ignored by
    /// contract for the Spot Healing Brush) — and `actionName` is the name
    /// the undo step will carry, used here only to name the tool in a
    /// refusal.
    ///
    /// The channel-target question is already settled upstream:
    /// `onStrokeBegin` refuses any stroke that would land on a channel from
    /// a tool that cannot paint coverage, and neither healing brush can, so
    /// no stroke reaches this method while an indicator names a channel.
    func commitHealOverlay(_ data: UnsafePointer<UInt8>, _ actionName: String) {
        // No pre-stroke handle means no open live-edit session — nothing to
        // replace and nothing to roll back. Unreachable today (the healing
        // brushes never paint coverage, so they always open one), but
        // committing into a document whose base is unknown is not something
        // to do on a guess.
        guard let document = document, let base = strokeBase else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        // §0.7(a): the two core wrappers THROW a documented cap message that
        // has to reach the user, and this is a plain non-throwing callback.
        // Latch the message rather than `try?`-ing it away.
        var thrown: String?
        var healed: RasterDocument?
        do {
            switch strokeTool {
            case .heal:
                let options = ToolOptionsStore.shared.heal
                healed = try base.healLayer(
                    idx, overlay: data, w: base.width, h: base.height,
                    strength: Self.healStrength(options))
            case .spotHeal:
                let options = ToolOptionsStore.shared.spotHeal
                // ring 0 = the core's automatic width (widened from below by
                // the footprint's own size, because a ring narrower than the
                // hole tiles), and seed 0 so the same stroke over the same
                // pixels always heals the same way — the tool exposes
                // neither dial; Content-Aware Fill's sheet is where a seed
                // is worth choosing.
                //
                // This is the one interactive path in the app that blocks for
                // SECONDS: the stroke's whole footprint is inpainted and
                // Poisson-blended at mouse-up, measured 2.4 s for a 200 px
                // brush dragged 800 px across a 2000 x 1500 document and
                // 4.4 s for a 1500 px drag on a 5000 x 4000 one. Say so with
                // the cursor before blocking, since nothing else on screen
                // can move once we do.
                healed = try Self.whileBusy {
                    try base.spotHealLayer(
                        idx, overlay: data, w: base.width, h: base.height,
                        strength: Self.healStrength(options), ring: 0, seed: 0,
                        sampleAllLayers: options.sampleAllLayers, preview: false)
                }
            default:
                // The canvas only fires this callback for the two healing
                // tools; anything else would be a wiring mistake, and
                // committing an unsolved overlay is the one outcome worth
                // refusing loudly.
                healed = nil
            }
        } catch let error as RasterCoreError {
            thrown = error.message
        } catch {
            thrown = error.localizedDescription
        }
        guard let result = healed else {
            // Roll the drag's preview back to the pre-stroke handle. Without
            // this a refused heal would COMMIT the raw clone the drag was
            // previewing — the unblended patch, carrying exactly the
            // illumination mismatch the tool exists to remove. Restoring the
            // base handle makes the endLiveEdit that follows a same-handle
            // no-op: no undo step, no dirty flag, no pixels moved.
            document.updateLiveEdit(base)
            if let message = thrown {
                presentHealFailure(message, actionName)
            } else {
                NSSound.beep()
            }
            return
        }
        document.updateLiveEdit(result)
    }

    /// Runs `work` with the busy cursor showing, and restores the tool's own
    /// cursor afterwards.
    ///
    /// The main thread is blocked for the whole of `work`, so this is the
    /// only feedback that can reach the screen: no progress bar can animate
    /// and no view can redraw while a synchronous core call is running. The
    /// cursor is pushed before the call because `NSCursor.set` reaches the
    /// window server immediately, and popped after — AppKit's own cursor-rect
    /// machinery re-asserts the tool cursor on the next mouse-moved event
    /// either way.
    ///
    /// It is not private, and the reason is that this file's spot heal is the
    /// SHORTEST of the three blocking commits in the phase, not the longest:
    /// the Patch tool's `healLayer` is bounded only by `doc_heal`'s
    /// 32-megapixel memory limit (measured 10.3 s of solve and 1.5 GB on a
    /// 5000 x 5000 selection) and Content-Aware Fill's Apply by
    /// `doc_inpaint`'s own worst permitted call (12.1 s). Both went through
    /// `applyRasterizingEdit` directly, with the ordinary crosshair still
    /// showing and nothing on screen changing, which is indistinguishable
    /// from a hang. Every commit that can block for seconds wears this.
    static func whileBusy<T>(_ work: () throws -> T) rethrows -> T {
        busyCursor.push()
        defer { NSCursor.pop() }
        return try work()
    }

    /// AppKit ships no public wait cursor; one is built once from an SF
    /// Symbol, the way `EditorTool.zoomCursor` builds the magnifier, falling
    /// back to the arrow if the symbol somehow fails to render.
    private static let busyCursor: NSCursor = {
        guard let icon = NSImage(
            systemSymbolName: "hourglass", accessibilityDescription: "Working")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        else { return .arrow }
        return NSCursor(image: icon.tinted(with: .black), hotSpot: NSPoint(x: 8, y: 8))
    }()

    /// The heal's strength: the tool's Opacity, which is what Opacity means
    /// for these two tools (§0.4 — Flow is forced to 1 at stroke begin so
    /// every dab deposits full coverage for the solve's domain to be, and
    /// the strength moved here).
    private static func healStrength(_ options: PaintToolOptions) -> Double {
        min(max(options.opacity, 0), 100) / 100
    }

    /// Explains a refused heal instead of beeping at it: the core's refusals
    /// are limits with numbers in them and an instruction ("heal it in
    /// shorter strokes"), and a beep throws that away. Mouse-up is over by
    /// the time this runs, so a sheet is safe — nothing is mid-drag.
    private func presentHealFailure(_ message: String, _ actionName: String) {
        let alert = NSAlert()
        // The core's messages are lowercase sentences meant to follow a
        // "… failed: " lead-in; an alert headline starts one.
        alert.messageText = message.prefix(1).uppercased() + message.dropFirst()
        alert.informativeText =
            "\(actionName) was rolled back: the layer is unchanged and no undo step was "
            + "added."
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
