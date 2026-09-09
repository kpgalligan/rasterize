import AppKit

/// Runs `body` inside an explicit undo group and closes every group it left
/// open ABOVE the level we started at — never below it.
///
/// This is the hoisted form of the flush that `AgentServer.performGroupedEdit`
/// and `AgentServer+Guides.editGuides` each carried inline. The two inline
/// copies drained
/// ABSOLUTELY (`while manager.groupingLevel > 0`), which is right on the path
/// they were written for — an agent tool call arrives through the
/// trampolines' `DispatchQueue.main.sync`, off the event path, where
/// NSUndoManager's implicit event group would otherwise stay open across
/// tool calls and merge every agent edit into one undo step — and wrong on
/// any other. Called inside a real AppKit event (the Actions window's Play
/// button, ⌃F, the command palette, Batch's main-run-loop timer) AppKit has
/// already opened its own implicit group for the event, the absolute drain
/// closes it, and AppKit's own end-of-event close then has no matching
/// begin. `ImageDocument.withReplayUndo` — the one undo entry an Action
/// replay leaves — registers through here for exactly that reason: it is
/// reached both from an AppKit event (the Actions window's Play button, ⌃F,
/// the command palette) and off it (`run_action` over MCP, Batch's timer).
///
/// Off the event path the base is 0, which is exactly the old absolute
/// drain — so every existing caller behaves as it did.
///
/// `body`'s value is returned, and the `defer` closes the group even when it
/// throws, so a step that fails mid-run can never leave a group open.
func withUndoGroup<T>(_ manager: UndoManager?, _ body: () throws -> T) rethrows -> T {
    guard let manager = manager else { return try body() }
    let base = manager.groupingLevel
    manager.beginUndoGrouping()
    defer {
        while manager.groupingLevel > base {
            manager.endUndoGrouping()
        }
    }
    return try body()
}
