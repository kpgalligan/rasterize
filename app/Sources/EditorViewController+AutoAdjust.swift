import AppKit

/// Image ▸ Auto Tone / Auto Contrast / Auto Color: Levels parameters derived
/// from the active layer's own histogram, then applied through the SAME
/// levels math every other Levels path runs. One undo step; a layer already
/// at full range writes nothing (the core returns no parameters, and
/// `performLayerEdit`'s nil beeps rather than registering a phantom step).
///
/// The three are commands, not adjustment layers and not dialogs: each is a
/// measurement of the pixels in front of it, so there is nothing to re-edit
/// later and nothing to preview. Their agent mirrors are `auto_tone`,
/// `auto_contrast` and `auto_color` (AgentServer+Adjustments.swift), which
/// take the same clipping fraction as an argument and report the nine
/// numbers each one derived.
extension EditorViewController {
    /// The share of counted pixels dropped at EACH end before the black and
    /// white points are read off the histogram. 0.1 % is Photoshop's own
    /// default in Auto Color Correction Options, for both ends, and it is
    /// what keeps a handful of hot pixels or a single blown specular from
    /// deciding where white is. The menu commands carry no dialog — the
    /// agent tools take `clip` when a picture needs a different one.
    private static let autoClip = 0.001

    /// Image ▸ Auto Tone (⇧⌘L): each channel's own histogram stretched to
    /// the full range, which corrects a cast as a side effect.
    @objc func autoTone(_ sender: Any?) {
        applyAutoLevels(RZ_AUTO_TONE, "Auto Tone", tool: "auto_tone")
    }

    /// Image ▸ Auto Contrast (⌥⇧⌘L): ONE black and white point read off the
    /// luma histogram and applied to all three channels, so the colour
    /// balance the photographer chose survives.
    @objc func autoContrast(_ sender: Any?) {
        applyAutoLevels(RZ_AUTO_CONTRAST, "Auto Contrast", tool: "auto_contrast")
    }

    /// Image ▸ Auto Color (⇧⌘B): Auto Tone's per-channel stretch plus a
    /// per-channel gamma that snaps the midtones neutral.
    @objc func autoColor(_ sender: Any?) {
        applyAutoLevels(RZ_AUTO_COLOR, "Auto Color", tool: "auto_color")
    }

    /// The three share one body. Both halves run inside the SAME
    /// `performLayerEdit` closure, on the image that edit is handed, for two
    /// reasons: the numbers must be derived from exactly the pixels they are
    /// applied to (with a colour plane or an alpha channel targeted, that is
    /// the plane, not the layer), and the pair is then one undo step.
    ///
    /// A nil from either half beeps and registers nothing. For
    /// `autoLevels` that is the honest "already at full range" case — the
    /// core refuses rather than writing an identity — and it is why the
    /// commands need no separate "nothing to do" alert. Like the app's other
    /// one-shot filters, they read and rewrite the whole layer: the marquee
    /// does not gate them, and neither does the agent twin.
    private func applyAutoLevels(_ mode: RzAutoMode, _ actionName: String, tool: String) {
        // The clip is NOT recorded: the menu commands carry no dialog, so
        // `Self.autoClip` is the only value they can ever use, and it is the
        // tools' own default. Recording it would freeze this build's constant
        // into every action.
        //
        // The TARGET cannot be recorded at all: `auto_tone`, `auto_contrast`
        // and `auto_color` take no `target` argument — they read and write
        // the whole layer — so an auto-adjust the user ran on the Red plane
        // or on an alpha channel has no twin that would do the same thing.
        // Replaying it as the plain tool would stretch all three channels and
        // produce a visibly different picture with nothing saying so, which
        // is exactly what the visible placeholder exists to prevent.
        let record: [ActionStep] =
            paintTarget.targetsPlaneOrChannel
            ? .unrecorded("\(actionName) (\(paintTarget.agentName(in: document?.doc)))")
            : .autoAdjust(tool)
        performLayerEdit(actionName, record: record) { image in
            guard let derived = image.autoLevels(
                mask: nil, mode: mode, clip: Self.autoClip)
            else { return nil }
            return image.levelsChannels(
                black: derived.black, white: derived.white, gamma: derived.gamma)
        }
    }
}
