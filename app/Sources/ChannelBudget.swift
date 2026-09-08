import AppKit

/// The channel budget, said out loud.
///
/// The core refuses Image Size, Canvas Size and every channel-CREATING
/// command outright once the channel list would break the .rz
/// total-channel-pixel budget (900 million channel pixels, nine full canvases)
/// or the 256-channel count cap: a document past either could be built and
/// edited, written by `rz_doc_save_native`, and then never reopened, so the
/// refusal lands where the user can still delete channels. What the core
/// cannot do is SAY so — `ImageDocument.applyEdit` turns a nil into a bare
/// `NSSound.beep()`, and nothing on screen hints that a full channel list is
/// why a 45 MP Image Size just failed.
///
/// So every path that can hit it asks first (`channelBudgetRefusal`, against
/// the core's own `rz_max_channels_at`) and shows the refusal the 100 MP
/// ceiling already shows next to them.
extension RasterDocument {
    /// Why this document's channels — plus `adding` more — do not fit a
    /// `width` x `height` canvas, or nil when they do.
    func channelBudgetRefusal(width: Int, height: Int, adding: Int = 0) -> String? {
        // A canvas that could not exist at all is NOT a channel refusal.
        // `maxChannels` answers 0 for a negative or absurd size, so without
        // this guard every out-of-range Image Size / Canvas Size on a
        // document that happens to carry channels would be reported as
        // "delete your channels" — advice that cannot work, and that costs
        // saved selections and imported mattes to follow. Refusing the SIZE
        // is the core's own job, and its message is the one that helps.
        let pixels = width.multipliedReportingOverflow(by: height)
        guard width >= 1, height >= 1, !pixels.overflow,
              pixels.partialValue <= RasterImage.maxResizePixels
        else { return nil }
        let wanted = channelCount + adding
        let allowed = RasterDocument.maxChannels(width: width, height: height)
        guard wanted > allowed else { return nil }
        let has = channelCount == 1 ? "1 alpha channel" : "\(channelCount) alpha channels"
        let fits = allowed == 1 ? "1 of them" : "\(allowed) of them"
        let canvas = "A \(width) × \(height) px canvas holds at most \(fits)"
        // Deleting channels only helps when what is being ADDED would itself
        // fit. Otherwise there may be nothing to delete (a freshly opened
        // photo holds none), and deleting every channel there is would still
        // not make room — so the honest remedy is the canvas.
        if adding > allowed {
            let more = adding == 1 ? "another channel" : "\(adding) more channels"
            return "\(canvas), so \(more) cannot be added however many are deleted. Make the "
                + "canvas smaller first."
        }
        if adding > 0 {
            return "\(canvas), and this document already has \(has). Delete channels in the "
                + "Channels panel, or make the canvas smaller."
        }
        return "\(canvas), and this document has \(has) — they would no longer fit, so the "
            + "size cannot change. Delete channels in the Channels panel first."
    }

    /// How many channels Add Luminosity Masks appends — the core's own
    /// "Lights 1".."Midtones 3" (three tones × three steps), restated so the
    /// refusal can be predicted before the call.
    static let luminosityMaskCount = 9
}

extension NSViewController {
    /// The channel-budget refusal, in the shape the Image Size and Canvas
    /// Size sheets already use for the 100 MP ceiling: a sheet on the
    /// controller's own window, or a modal alert when it has none.
    func presentChannelBudgetAlert(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Too Many Channels"
        alert.informativeText = reason
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
