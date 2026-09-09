import AppKit

/// An app-modal window hosting one `makeSheetView` card — the presentation
/// for a dialog that has to run when there is no window to hang a sheet
/// from, and whose Cancel must be able to abandon the thing that was about
/// to be created.
///
/// **Why this exists at all.** Every other dialog in the app is a
/// document-modal sheet, which is the right default: it belongs to a window
/// and does not stop the world. But `ImageDocument.read(from:ofType:)` runs
/// synchronously, on the main thread, BEFORE `makeWindowControllers()` — so
/// during a RAW open there is no window, no document and no run loop to
/// return to. The RAW Develop dialog has to decide before the pixels land
/// and has to be able to open nothing at all, and only an app-modal
/// presentation can do that. It is the first `NSApp.runModal(for:)` in the
/// app, and it is a shared file rather than a private detail because Batch
/// needs the same thing.
///
/// The card is any view the `Sheets.swift` builders produce, so a modal
/// dialog looks exactly like a sheet: same 22pt insets, same title, same
/// button row — and `makeButtonRow` gives Return and Escape for free.
final class ModalCardWindowController: NSWindowController {
    init(title: String, card: NSView) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: card.fittingSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.contentView = card
        window.setContentSize(card.fittingSize)
        // A modal window that vanishes when the user clicks another app has
        // no way back: the modal session still owns the main run loop, so
        // nothing else in this app can be reached to bring it forward.
        window.hidesOnDeactivate = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ModalCardWindowController does not support NSCoder")
    }

    /// Runs the modal session and returns `.OK` or `.cancel`.
    ///
    /// The three lines before `runModal` are for the case that fires FIRST
    /// in real life: double-clicking a RAW in Finder while Rasterize is not
    /// running puts this inside `NSDocumentController`'s launch-time open,
    /// before the app is active. A modal window raised on an inactive app
    /// appears behind everything, reachable only through the Dock, while a
    /// modal run loop spins inside launch — so the app is activated, the
    /// window centred, and it is made key and ordered front explicitly.
    func runModal() -> NSApplication.ModalResponse {
        guard let window = window else { return .cancel }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        return response
    }

    /// Ends the session started by `runModal`, from a button action.
    func end(_ response: NSApplication.ModalResponse) {
        NSApp.stopModal(withCode: response)
    }
}
