import AppKit

/// Where actions live: one JSON file per action in
/// `~/Library/Application Support/Rasterize/actions`, beside the assistant's
/// API key.
///
/// The recipe is `Assistant.saveFile`'s — create the directory with
/// intermediates, write atomically — minus its 0600, which is about a
/// secret. The app is not sandboxed (there is no `.entitlements` anywhere),
/// so no security-scoped bookmark plumbing is needed to read or write there.
///
/// **`RZ_ACTIONS_DIR` overrides the folder when it is set**, the same
/// precedent as `RZ_AGENT_PORT`: every test instance points it at a
/// scratch directory, so verification can never write into — or delete from
/// — the user's own library.
enum ActionLibrary {
    /// Posted after any change to the folder's contents made through this
    /// type, so the Actions window and the Batch sheet reload.
    ///
    /// `userInfo[changedFileKey]` carries the ONE file that changed when the
    /// poster knows it — see `postDidChange(changed:)`.
    static let didChange = Notification.Name("rasterizeActionLibraryDidChange")

    /// The `URL` of the single file a `didChange` was posted for.
    static let changedFileKey = "changedFile"

    /// Present in `userInfo` when the poster has already put the new decode
    /// in the cache, so the invalidator must leave that key alone — see
    /// `save`.
    private static let cacheIsCurrentKey = "cacheIsCurrent"

    /// Posts `didChange`, naming the one file that changed when the caller
    /// knows it so the decode cache drops that key alone.
    ///
    /// A post with no URL still clears the whole cache: that is the honest
    /// answer for a change this type did not make (a hand-edited file, a
    /// Finder move) and it is what keeps the fallback safe.
    static func postDidChange(changed url: URL?) {
        postDidChange(changed: url, cacheIsCurrent: false)
    }

    private static func postDidChange(changed url: URL?, cacheIsCurrent: Bool) {
        var userInfo = url.map { [changedFileKey: $0] as [String: Any] }
        if cacheIsCurrent { userInfo?[cacheIsCurrentKey] = true }
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: userInfo)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The actions folder, created on demand by the writers.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["RZ_ACTIONS_DIR"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Rasterize", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
    }

    // MARK: - Reading

    /// One file's SUMMARY, kept until the file itself changes.
    private struct CacheEntry {
        let modified: Date
        let size: Int
        let result: ActionSummaryResult
    }

    /// The summary cache, keyed by path. Main-thread only, like everything
    /// else in this feature.
    ///
    /// **It exists because reading the library is on two hot paths.** Every
    /// recorded step posts `ActionRecorder.didChange`, which reloads the
    /// Actions window; and AppKit calls `validateMenuItem` for File ▸
    /// Automate ▸ Play on every menu update — so a re-read of every file was
    /// happening once per brush stroke and once per File-menu click.
    /// Measured before this cache: a single load() of one large recorded
    /// action took 2.08 s, so a user who had saved one long paint session
    /// stalled for two seconds every stroke and every time they opened a
    /// menu.
    ///
    /// **It holds summaries and not actions, which is what bounds it.** It
    /// used to hold every file's full decode for the life of the process:
    /// measured, ten 3.1 MB recordings added 186 MB of resident memory that
    /// was never given back (the cache is pruned only for files that
    /// disappear, and one action a user never opens again cannot be evicted
    /// by anything else). A summary is a name, four counts and three dates,
    /// so the whole cache is now a few hundred bytes per file whatever those
    /// files hold, and `decoded` below keeps exactly ONE full decode.
    private static var cache: [String: CacheEntry] = [:]

    /// The one full decode the library keeps: the last action actually
    /// opened, run or edited.
    ///
    /// A single slot rather than a dictionary, deliberately. The callers that
    /// need whole steps ask about ONE action at a time — the Actions window's
    /// selection (re-asked on every reload, so it must not re-decode), a
    /// `run_action`, a Batch run, `list_actions {name}` — and a slot cannot
    /// accumulate. Validated against its own file's mtime and size on every
    /// read, exactly as `cache` is, so it can never serve stale bytes.
    private static var decoded: (path: String, modified: Date, size: Int, action: Action)?

    /// Drops the changed file's decode whenever anything changes the folder,
    /// so a write made around `save`/`delete` — the JSON editor writes its own
    /// file, and `delete_action` removes a broken one directly — is picked up
    /// too. `queue: nil` delivers synchronously on the posting thread, so the
    /// clear always happens before the reload that same notification triggers.
    ///
    /// **One key, not the whole cache.** Every ordinary Actions-window
    /// gesture writes a file and reloads: `mutateSteps` saves for a single
    /// Enabled toggle, a Move Up or a drag-reorder, and every recorded step
    /// posts too. Clearing everything made that reload re-decode the WHOLE
    /// library on the main thread, so one checkbox on a small action froze
    /// the app for as long as the biggest unrelated file in the folder took
    /// to decode — measured 2.2 s with one 4.6 MB recorded action present and
    /// 13.0 s with a 30 MB one, and the same freeze again on the next File
    /// menu (`validateMenuItem` → `mostRecentlyModified()`). Every other
    /// file's entry is still checked against its own mtime and size below,
    /// so dropping one key can never serve stale bytes for another.
    private static let invalidator: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: didChange, object: nil, queue: nil
    ) { note in
        guard let url = note.userInfo?[changedFileKey] as? URL else {
            cache.removeAll()
            decoded = nil
            return
        }
        // …unless the poster wrote those very bytes and seeded the decode it
        // wrote them from (`save`). Dropping the key there meant the reload
        // this same notification triggers re-read and re-decoded a file the
        // app had just had in its hands. The guard covers BOTH caches, since
        // `seed` fills both.
        guard note.userInfo?[cacheIsCurrentKey] == nil else { return }
        cache.removeValue(forKey: url.path)
        if decoded?.path == url.path { decoded = nil }
    }

    /// Every `.json` in the folder with its URL, SUMMARISED once per version
    /// of each file. Directory order, not display order.
    ///
    /// Nothing here decodes a step's arguments — see `Action.decodeSummary`
    /// for why, and `action(at:)` for the read that does.
    ///
    /// Internal because the two lists a user picks an action from — the
    /// Actions window's pop-up and Batch's — need the URL beside the name:
    /// that is the file their steps are read from, so two files that a
    /// hand-edit gave one display name cannot resolve to each other.
    static func entries() -> [(url: URL, result: ActionSummaryResult)] {
        _ = invalidator
        var out: [(url: URL, result: ActionSummaryResult)] = []
        var present: Set<String> = []
        for (url, modified, size) in files() {
            present.insert(url.path)
            if let hit = cache[url.path], hit.modified == modified, hit.size == size {
                out.append((url, hit.result))
                continue
            }
            let result: ActionSummaryResult
            if let data = try? Data(contentsOf: url) {
                switch Action.decodeSummary(data) {
                case .success(let summary): result = .ok(summary)
                case .failure(let error):
                    result = .broken(file: url.lastPathComponent, reason: error.message)
                }
            } else {
                result = .broken(file: url.lastPathComponent, reason: "could not be read")
            }
            cache[url.path] = CacheEntry(modified: modified, size: size, result: result)
            out.append((url, result))
        }
        // A file that has gone takes its cache entry with it, so the cache
        // can never outgrow the folder.
        cache = cache.filter { present.contains($0.key) }
        return out
    }

    /// The folder's `.json` files in name order, each with the two values
    /// every cache entry is keyed on.
    private static func files() -> [(url: URL, modified: Date, size: Int)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])) ?? []
        return contents
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return (
                    url: url, modified: values?.contentModificationDate ?? .distantPast,
                    size: values?.fileSize ?? -1)
            }
    }

    /// One file's FULL decode — every step, every argument — through the
    /// single-slot cache above. `.broken` carries the reason, which for a
    /// file whose summary read cleanly is a failure only this read can find
    /// (a malformed symbol, a non-finite number) and which names the step
    /// and the argument path.
    static func action(at url: URL) -> ActionLoadResult {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        let modified = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? -1
        if let hit = decoded, hit.path == url.path, hit.modified == modified, hit.size == size {
            return .ok(hit.action)
        }
        guard let data = try? Data(contentsOf: url) else {
            return .broken(file: url.lastPathComponent, reason: "could not be read")
        }
        switch Action.decode(data) {
        case .success(let action):
            decoded = (path: url.path, modified: modified, size: size, action: action)
            return .ok(action)
        case .failure(let error):
            return .broken(file: url.lastPathComponent, reason: error.message)
        }
    }

    /// Every `.json` in the folder, sorted by display name, with a file that
    /// would not parse listed as `.broken` and its reason beside it.
    ///
    /// A broken file NEVER takes the library with it and is never silently
    /// dropped: a user who hand-edits an action has to be able to see what
    /// they broke, and where.
    static func summaries() -> [ActionSummaryResult] {
        entries().map { $0.result }.sorted { a, b in
            switch (a, b) {
            case (.ok(let x), .ok(let y)):
                return x.name.localizedStandardCompare(y.name) == .orderedAscending
            case (.ok, .broken): return true
            case (.broken, .ok): return false
            case (.broken(let x, _), .broken(let y, _)):
                return x.localizedStandardCompare(y) == .orderedAscending
            }
        }
    }

    /// Every action that summarised cleanly, in the library's display order.
    static func names() -> [String] {
        summaries().compactMap { if case .ok(let it) = $0 { return it.name } else { return nil } }
    }

    /// The action most recently written — what File ▸ Automate ▸ Play offers,
    /// since "the last one" means the one just recorded or edited, not the
    /// one that sorts first. An action with no `modified` stamp (a
    /// hand-written file) sorts last rather than winning by accident.
    ///
    /// The URL comes back with it so the caller that then wants the STEPS
    /// asks for that file rather than looking the name up again.
    static func mostRecentlyModified() -> (url: URL, summary: ActionSummary)? {
        var best: (url: URL, summary: ActionSummary)?
        for (url, result) in entries() {
            guard case .ok(let summary) = result else { continue }
            guard let current = best else {
                best = (url, summary)
                continue
            }
            if (current.summary.modified ?? .distantPast)
                < (summary.modified ?? .distantPast)
            {
                best = (url, summary)
            }
        }
        return best
    }

    /// One action by display name, case-insensitively — the name is what the
    /// user typed and what every tool takes. Fully decoded, because every
    /// caller of this one is about to run or rewrite the steps.
    static func action(named name: String) -> Action? {
        guard case .ok(let action)? = entry(named: name) else { return nil }
        return action
    }

    /// One SUMMARY by display name — the collision checks, which need to know
    /// that a name is taken and how big the action behind it is, not what its
    /// steps are.
    static func summary(named name: String) -> ActionSummary? {
        for (_, result) in entries() {
            guard case .ok(let summary) = result,
                  summary.name.compare(name, options: .caseInsensitive) == .orderedSame
            else { continue }
            return summary
        }
        return nil
    }

    /// One entry by name, INCLUDING a file that would not parse.
    ///
    /// A broken action still has to be findable: "run the action called X"
    /// must answer "X is broken because …", not "there is no X", or the one
    /// thing a hand-editing user needs to hear is the one thing they cannot
    /// get. A file that does not decode has no `name` to match on, so it is
    /// matched on the two things it still has — the `name` its JSON claims,
    /// read leniently, and its own slug.
    ///
    /// The name is matched on the SUMMARY and only the winner is decoded, so
    /// finding an action costs one file's steps and not the library's. A file
    /// whose summary read cleanly can still come back `.broken` here — that
    /// is where a bad symbol or a non-finite number deep in an argument is
    /// caught, and it is caught before anything runs.
    static func entry(named name: String) -> ActionLoadResult? {
        let wanted = slug(for: name)
        var broken: ActionLoadResult?
        for (url, result) in entries() {
            switch result {
            case .ok(let summary):
                if summary.name.compare(name, options: .caseInsensitive) == .orderedSame {
                    return action(at: url)
                }
            case .broken(let file, let reason):
                // Kept, not returned yet: a VALID action of that name later
                // in the folder still wins over a broken one.
                let claimed =
                    (try? Data(contentsOf: url))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                    .flatMap { ($0 as? [String: Any])?["name"] as? String }
                let matches =
                    claimed?.compare(name, options: .caseInsensitive) == .orderedSame
                    || url.deletingPathExtension().lastPathComponent == wanted
                if matches, broken == nil {
                    broken = .broken(file: file, reason: reason)
                }
            }
        }
        return broken
    }

    // MARK: - Writing

    /// Writes `action`, replacing any file that already holds an action of
    /// the same display name.
    ///
    /// A NEW name whose slug collides with an existing, differently-named
    /// action takes the next free `-2`, `-3`, … so two actions can share a
    /// slug-worthy name without one silently overwriting the other.
    @discardableResult
    static func save(_ action: Action) throws -> URL {
        var action = action
        action.modified = Date()
        if action.created == nil { action.created = action.modified }
        let url = try destination(for: action.name)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try action.encoded().write(to: url, options: [.atomic])
        } catch {
            throw Failure(
                message: "could not write \(url.lastPathComponent): "
                    + error.localizedDescription)
        }
        // The decode is already in hand — it is what those bytes were
        // written FROM — so it goes straight into the cache instead of being
        // dropped and immediately re-produced. Every ordinary Actions-window
        // gesture saves and reloads (an Enabled checkbox, Move Up, a
        // drag-reorder, Delete Step), and the reload runs inside the
        // notification below: dropping the key made each of those pay a full
        // re-read and re-decode of the file just written — measured at 8.7 s
        // for one long recorded paint session, on top of the write.
        seed(action, at: url)
        postDidChange(changed: url, cacheIsCurrent: true)
        return url
    }

    /// Puts a decode the app itself produced into BOTH caches under the file
    /// it was just written to: the summary the listings read, and the one
    /// full-decode slot, since the action just saved is by far the likeliest
    /// one to be asked for next (an Enabled toggle saves and then reloads the
    /// row it toggled).
    ///
    /// Keyed on the file's own mtime and size, read back AFTER the write, so
    /// `entries()` validates this entry exactly as it validates one it
    /// decoded itself — and so a write that landed differently than expected
    /// simply misses and is re-read. When those values cannot be read there
    /// is nothing to key on, and the honest answer is the old one: drop the
    /// key and let the next read decode it.
    private static func seed(_ action: Action, at url: URL) {
        guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate, let size = values.fileSize
        else {
            cache.removeValue(forKey: url.path)
            if decoded?.path == url.path { decoded = nil }
            return
        }
        cache[url.path] = CacheEntry(
            modified: modified, size: size, result: .ok(action.summary))
        decoded = (path: url.path, modified: modified, size: size, action: action)
    }

    /// Deletes the action with this display name. An unknown name throws
    /// rather than succeeding quietly, so a mistyped `delete_action` is
    /// visible.
    static func delete(_ name: String) throws {
        guard let url = fileURL(forActionNamed: name) else {
            throw Failure(message: "No action named \"\(name)\". Call list_actions.")
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw Failure(
                message: "could not delete \(url.lastPathComponent): "
                    + error.localizedDescription)
        }
        postDidChange(changed: url)
    }

    /// Renames an action: the display name is authoritative, so this rewrites
    /// the file under the new name's slug and removes the old one.
    static func rename(_ name: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(message: "an action needs a name") }
        guard var action = action(named: name) else {
            throw Failure(message: "No action named \"\(name)\". Call list_actions.")
        }
        guard trimmed.compare(name, options: .caseInsensitive) != .orderedSame else { return }
        let old = fileURL(forActionNamed: name)
        action.name = trimmed
        try save(action)
        // `save` posted for the new file; this one names the old one it just
        // removed, so both keys leave the cache and nothing else is re-read.
        if let old = old { try? FileManager.default.removeItem(at: old) }
        postDidChange(changed: old)
    }

    // MARK: - Names on disk

    /// The file that currently holds the action with this display name, by
    /// reading the files rather than by re-deriving a slug: the name is
    /// authoritative and a hand-placed file may be called anything.
    static func fileURL(forActionNamed name: String) -> URL? {
        for (url, result) in entries() {
            guard case .ok(let summary) = result,
                  summary.name.compare(name, options: .caseInsensitive) == .orderedSame
            else { continue }
            return url
        }
        return nil
    }

    /// Where a save goes: the existing file for that name, or a fresh
    /// non-colliding slug.
    private static func destination(for name: String) throws -> URL {
        if let existing = fileURL(forActionNamed: name) { return existing }
        let base = slug(for: name)
        var candidate = base
        var suffix = 2
        while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(candidate + ".json").path)
        {
            candidate = "\(base)-\(suffix)"
            suffix += 1
            guard suffix < 1000 else {
                throw Failure(message: "too many actions share the name \"\(name)\"")
            }
        }
        return directory.appendingPathComponent(candidate + ".json")
    }

    /// A display name as a file name: lower-cased, every run of
    /// non-alphanumerics collapsed to one `-`, trimmed, capped at 60
    /// characters so no name can produce a path the filesystem refuses, and
    /// `action` when nothing is left (a name of pure punctuation).
    static func slug(for name: String) -> String {
        var out = ""
        var pendingDash = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
                if out.count >= 60 { break }
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "action" : out
    }
}
