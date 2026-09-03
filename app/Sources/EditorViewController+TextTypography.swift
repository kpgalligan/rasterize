import AppKit

// The text tool's typography: the style the tool types with (built from the
// controller's live family/size/alignment plus the options store's weight,
// italic, tracking, leading, baseline shift, underline and strikethrough),
// and the restore of a reopened layer's description into the bar and the
// canvas session. One builder in each direction, so the session previews
// exactly what the commit renders (TextStyle.attributes): the canvas
// session's NSTextView and TextLayer.render both take their attributes from
// the very TextStyle built here, and the commit's payload is built from
// the session's copy of it (ImageCanvasView.commitTextSession).
extension EditorViewController {
    /// The style the text tool types with: the live family/size/alignment
    /// plus the store's typography (weight, italic, tracking, leading,
    /// baseline shift, underline, strikethrough). The canvas session and
    /// every new payload are built from it. The store's numbers are read
    /// through the bar's own ranges (`TextToolOptions.clampingTypography`),
    /// so a bad UserDefaults blob can neither produce a description `decode`
    /// would reject as "not text" nor type with a value the bar cannot
    /// show.
    func currentTextStyle() -> TextStyle {
        let text = ToolOptionsStore.shared.text.clampingTypography()
        return TextStyle(
            family: fontFamily, size: Double(fontSize),
            weight: text.weight,
            italic: text.italic,
            tracking: text.tracking,
            leading: text.leading,
            baselineShift: text.baselineShift,
            underline: text.underline,
            strikethrough: text.strikethrough,
            alignment: textAlignment)
    }

    /// Restores a layer's description into the options bar (live copies +
    /// store) and the canvas session style, so the session draws with the
    /// description's OWN face — a family that is not installed here still
    /// previews exactly what an explicit re-render produces (the fallback
    /// face), while the bar's family popup keeps its last installed choice.
    ///
    /// EVERY typography field lands in the store, not just the ones with a
    /// live copy: any later options-bar edit — even the color swatch —
    /// rebuilds the session's style from the store (`toolOptionsEdited`),
    /// so a field left behind would silently revert the layer to whatever
    /// the user last typed NEW text with on the first tweak. No field is
    /// reset to a default any more; the description carries them all —
    /// CLAMPED to the bar's ranges (`TextToolOptions.clampingTypography`):
    /// a description can carry a tracking or leading the bar cannot
    /// express, and stored raw it would poison every new session until
    /// the field was reset. The session keeps the layer's exact values.
    func applyTextOptions(_ payload: TextLayerPayload) {
        let style = payload.style
        if style.isInstalled {
            fontFamily = style.family
        }
        fontSize = min(max(CGFloat(style.size), 6), 500)
        setPaintColor(payload.nsColor)
        textAlignment = payload.nsAlignment
        canvas.textStyle = style
        var text = ToolOptionsStore.shared.text
        text.family = fontFamily
        text.size = Double(fontSize)
        text.alignmentIndex = Self.alignmentIndex(textAlignment)
        text.weight = payload.weight
        text.italic = payload.italic
        text.tracking = payload.tracking
        text.leading = payload.leading
        text.baselineShift = payload.baselineShift
        text.underline = payload.underline
        text.strikethrough = payload.strikethrough
        ToolOptionsStore.shared.text = text.clampingTypography()
        optionsBar.refreshValues()
    }
}
