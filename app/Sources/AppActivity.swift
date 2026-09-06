import Foundation

/// The activity assertion every tool call runs inside, and the reason there
/// has to be one.
///
/// **App Nap demotes an app that hogs its main thread in the background, and
/// it does not undo it.** Measured on the built app driven over MCP, a
/// 2000 x 1500 photograph, a 300 x 300 Content-Aware Fill: 0.75 s on a
/// freshly launched app, four times in a row. Run one megapixel fill (7 s of
/// solid main-thread compute) and the same 300 x 300 fill then measures
/// 3.4-3.9 s — 5x — for the rest of the session, whatever is in the
/// foreground and however long the app then sits idle. The process burns CPU
/// the whole time (its CPU time tracks wall time), so the cycles themselves
/// are slower rather than the work being descheduled, and the identical core
/// call in a plain command-line process is unaffected before and after
/// (0.67 s both). Launching the app with `-NSAppSleepDisabled YES` removes
/// the effect completely — 0.73-0.75 s before and after the megapixel fill —
/// which is what identifies it.
///
/// That 5x is how this phase's Content-Aware Fill came to be documented at
/// "about seven seconds" and measured at 37: the seven was the first fill in
/// a session, the 37 every fill after it. Nothing about the algorithm
/// changed between them.
///
/// A tool call is user-initiated work by definition — a person asked Claude
/// for it — so it says so, for as long as it runs. `NSActivityUserInitiated`
/// without the idle-system-sleep bit is the polite form: it suppresses App
/// Nap, which is the whole point here, and still lets an idle machine sleep
/// under a caller that has wandered off.
///
/// The UI's own long edits do not need this: a person has to be in the app
/// to start one, and a foreground app is not napped. The two agent
/// trampolines are the paths that run while the app sits in the background,
/// and they are where this is held.
enum AppActivity {

    /// Runs `body` inside a user-initiated activity assertion.
    static func userInitiated<T>(_ reason: String, _ body: () -> T) -> T {
        let process = ProcessInfo.processInfo
        let token = process.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: reason)
        defer { process.endActivity(token) }
        return body()
    }
}
