import AppKit

/// The step counter and Stop button behind a UI-driven replay.
///
/// **Why it is shaped like this.** `ActionPlayer.run` is synchronous, on the
/// main thread, and has to stay that way: `run_action` arrives through the
/// agent trampoline's `DispatchQueue.main.sync` and must answer with a
/// report, and Batch drives whole files from a run-loop timer. So the loop
/// cannot be broken into turns without forking the player in two. What it
/// can do is let AppKit draw and answer the mouse BETWEEN steps, which is
/// exactly what a modal SESSION is for: `runModalSession` services pending
/// events and returns immediately. The player calls `tick` once per step; a
/// 40-step retouch on a big photograph therefore shows "Step 12 of 40" and a
/// Stop that works, instead of a beach ball with no way out.
///
/// **It appears only if the run is slow.** Most actions finish in a blink,
/// and a window that flashes on and off is worse than none — so nothing is
/// shown until `showDelay` has passed, and a fast run never begins a modal
/// session at all.
///
/// Stopping is polite, not violent: the flag is read between steps, never
/// inside one. A core call cannot be interrupted, and abandoning a
/// half-applied filter would leave a picture nobody asked for.
final class ActionRunProgress {
    /// How long a run may take before the panel appears.
    private static let showDelay: TimeInterval = 0.25

    private var window: NSWindow?
    private var session: NSApplication.ModalSession?
    private var label: NSTextField?
    private var started = Date()
    private var total = 0
    private var name = ""
    private var stopped = false

    init() {}

    deinit {
        // A session left open would own the main run loop for good. `end()`
        // is called from the player's own `defer`, so this only ever fires
        // for a progress that was never begun.
        assert(session == nil, "an ActionRunProgress was released mid-session")
    }

    // MARK: - The player's three calls

    func begin(action: String, steps: Int) {
        assert(Thread.isMainThread)
        name = action
        total = steps
        started = Date()
        stopped = false
    }

    /// Draws "Step N of M" and services the Stop button. False means the
    /// user pressed Stop and the run must end here.
    func tick(step: Int) -> Bool {
        assert(Thread.isMainThread)
        guard !stopped else { return false }
        if session == nil {
            guard Date().timeIntervalSince(started) >= Self.showDelay else { return true }
            show()
        }
        label?.stringValue = "Step \(step) of \(total)"
        // This services the main run loop in `NSModalPanelRunLoopMode`, which
        // also DRAINS the main dispatch queue — so both agent trampolines'
        // `DispatchQueue.main.sync` can deliver a tool call right here,
        // inside the run's suppressed undo window. That is why a replay is
        // exclusive and refuses foreign calls for its length
        // (`ActionPlayer.isPlaying`); without it the edit landed, reported
        // `ok`, registered no undo of its own and was reverted by the run's
        // single snapshot restore.
        if let session = session, NSApp.runModalSession(session) != .continue {
            stopped = true
        }
        return !stopped
    }

    func end() {
        assert(Thread.isMainThread)
        if let session = session {
            NSApp.endModalSession(session)
            self.session = nil
        }
        window?.orderOut(nil)
        window = nil
        label = nil
    }

    // MARK: - The panel

    private func show() {
        let status = NSTextField(labelWithString: "Step 1 of \(total)")
        status.font = DS.mono(12)
        status.textColor = DS.textMuted
        label = status

        let content = NSStackView(views: [status])
        content.orientation = .vertical
        content.alignment = .leading

        let stop = StickerButton(
            title: "Stop", style: .secondary, target: self, action: #selector(stopClicked(_:)))
        // Built by hand rather than with `makeButtonRow`, which pairs a
        // Cancel with an Apply: a run in flight has one thing to say. Escape
        // is the same key every other dialog's Cancel carries.
        stop.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        let row = NSStackView(views: [spacer, stop])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let card = makeSheetView(
            title: "Playing “\(name)”",
            hint: "Stop leaves the steps already applied in place — one ⌘Z undoes the whole run.",
            content: content, buttonRow: row, width: 360)
        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: card.fittingSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Action"
        panel.contentView = card
        panel.setContentSize(card.fittingSize)
        // The same reason `ModalCardWindowController` gives: a modal window
        // that hides when the user clicks another app cannot be brought back,
        // because the session owns the run loop.
        panel.hidesOnDeactivate = false
        panel.center()
        window = panel
        session = NSApp.beginModalSession(for: panel)
    }

    @objc private func stopClicked(_ sender: Any?) {
        stopped = true
    }
}
