import AppKit

/// File ▸ Automate ▸ Actions… — the library window.
///
/// A WINDOW and not a fifth right-panel tab, decided once: `DS.panelWidth`
/// is 304 and `PanelTabsView` builds equal-width tabs, so a fifth would give
/// each 60.8 pt and truncate "Channels" and "Assistant"; the library is
/// app-wide rather than per-document, so a panel tab would be one copy of the
/// same list per open window; and it must exist with NO document open, to
/// edit or delete an action or to start a Batch.
///
/// It hosts a real `contentViewController`, unlike `WelcomeWindowController`,
/// which sets `contentView` directly — a view controller is what lets Edit
/// JSON be an ordinary `presentAsSheet` sheet instead of a second window.
final class ActionsWindowController: NSWindowController {
    static let shared = ActionsWindowController()

    /// Whether the saved frame has been consulted yet. Positioning happens
    /// once per launch: after that the window is wherever the user left it,
    /// and re-centring on every File ▸ Automate ▸ Actions… would throw that
    /// away.
    private var hasPositioned = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Actions"
        // 420 wide fits the footer's eight buttons and a readable step row;
        // 480 tall shows ten rows of `DS.layerRow` plus the chrome.
        window.minSize = NSSize(width: 420, height: 480)
        window.setFrameAutosaveName("RasterizeActionsWindow")
        // A shared window outlives its own close: closing it must not
        // deallocate the singleton's window out from under the next show().
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = ActionsViewController()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ActionsWindowController does not support NSCoder")
    }

    /// Brings the library window up, centring it the first time.
    func show() {
        guard let window = window else { return }
        if !hasPositioned {
            hasPositioned = true
            // `setFrameAutosaveName` only names the frame for SAVING; the
            // restore is this call, and it answers false the first time the
            // window is ever opened on this machine.
            if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        }
        let controller = contentViewController as? ActionsViewController
        controller?.reload()
        window.makeKeyAndOrderFront(nil)
        // The footer's GhostButtons carry nil targets, and a nil-target
        // action starts its search at the key window's FIRST RESPONDER.
        // Measured, both halves: a window whose first responder is the
        // window itself has the chain NSWindow → NSWindowController, which
        // skips the content view controller entirely — and the step table
        // refuses first responder on purpose; with the controller made first
        // responder instead, `NSApp.target(forAction:to:from:)` resolves a
        // nil-target button straight to it, while a selector it does not
        // implement (Record/Stop, which is `AppDelegate`'s) still travels on
        // to the app delegate. That is what lets the buttons, the row menu
        // and File ▸ Automate share one set of handlers.
        if let controller = controller { window.makeFirstResponder(controller) }
        NSApp.activate()
    }
}
