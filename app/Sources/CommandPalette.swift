import AppKit

/// The command palette's model: what a runnable command is, where the list
/// comes from, and how a query is scored against it.
///
/// Everything here is pure or read-only — the menu walk reads `NSApp.mainMenu`
/// and builds values, and the scoring is a function over
/// `(query, candidates)` with no state of its own. The panel that shows the
/// result lives in `CommandPaletteWindowController.swift`.
///
/// **Why a menu walk rather than a second list of commands.** Every command
/// this app has is already a menu item with a selector, a validation rule and
/// a title; a hand-kept palette catalogue would be a second statement of all
/// three and would rot on the next feature. The walk cannot go stale, and it
/// costs nothing: the main menu is built once at launch and never rebuilt, so
/// re-walking it on every open is always current.
struct CommandPaletteItem {
    /// The leaf title, exactly as the menu spells it — `Levels…`.
    let title: String
    /// The whole path to it, for the row's second line and for rank 4 —
    /// `Image ▸ Adjustments ▸ Levels…`.
    let path: String
    /// The item's key equivalent as a person reads it (`⇧⌘K`), empty when it
    /// has none.
    let shortcut: String
    /// Menu order, 0-based over the whole walk. The last tie-breaker, so two
    /// commands that score and measure identically still list in the order
    /// the menus put them in.
    let order: Int
    /// The item itself. It is passed back as `sender` when the command runs,
    /// because handlers read it — `setWorkingSpace(_:)` reads `tag`, the
    /// title-flipping items read their own title — and a synthesised stand-in
    /// would lie to them. Menu items live as long as the app, and the list is
    /// rebuilt on every open, so holding one costs nothing.
    let menuItem: NSMenuItem

    /// `title` and `path` normalised once, at walk time, so a keystroke costs
    /// only the comparison and never the normalisation.
    let normalizedTitle: String
    let normalizedPath: String

    /// The same two strings with `&` read as the WORD "and", for the items
    /// that contain one; nil for the rest, which is nearly all of them.
    ///
    /// A query is scored against both forms and keeps the better score, so
    /// "Black & White…" answers to `blackwhite` (the `&` dropped, which is
    /// how a fast typist spells it) and to `black and white` (the `&` read
    /// aloud, which is how the command is spoken) alike. One normalisation
    /// cannot do both: dropping the `&` makes the candidate SHORTER than the
    /// spoken query, and no band of `score` can match a needle longer than
    /// its haystack.
    let expanded: (title: String, path: String)?

    var action: Selector? { menuItem.action }
    var target: AnyObject? { menuItem.target }
}

enum CommandPalette {
    /// At most 20 rows, per the palette's matching rule: past that a list is
    /// no longer something a reader scans, and the answer is a longer query.
    static let maxRows = 20

    /// Menu nesting this walk will follow. The deepest menu in the app is
    /// three (`File ▸ Automate ▸ Batch…`); six is a defensive bound so a
    /// pathological or system-injected cycle cannot spin here.
    private static let maxDepth = 6

    // MARK: - The walk

    /// Every command that can run RIGHT NOW, in menu order.
    ///
    /// `NSMenu.update()` is what fills `isEnabled` in: with `autoenablesItems`
    /// (the default, and what this app relies on everywhere) an item's enabled
    /// state is the answer `validateUserInterfaceItem` / `validateMenuItem`
    /// gives, and that answer is only refreshed when the menu is updated. So
    /// each menu is updated before its items are read, exactly as opening it
    /// would.
    ///
    /// Disabled items are dropped rather than listed greyed out: the palette
    /// is a way to RUN something, and a list whose rows might do nothing when
    /// picked is worse than a shorter list.
    static func commands() -> [CommandPaletteItem] {
        var out: [CommandPaletteItem] = []
        guard let main = NSApp.mainMenu else { return out }
        collect(main, path: [], into: &out, depth: 0)
        return out
    }

    private static func collect(
        _ menu: NSMenu, path: [String], into out: inout [CommandPaletteItem], depth: Int
    ) {
        guard depth < maxDepth else { return }
        menu.update()
        for item in menu.items {
            // A separator has no command; a hidden item is not offered by the
            // menu either (the app hides the alternate ⌘= Zoom In this way);
            // an alternate is the same command under a held modifier and
            // would list twice.
            if item.isSeparatorItem || item.isHidden || item.isAlternate { continue }
            if let submenu = item.submenu {
                // Recurse WITHOUT testing the parent's own enabled state:
                // AppKit derives a submenu parent's state from its children,
                // and the children are what this is after.
                collect(submenu, path: path + [item.title], into: &out, depth: depth + 1)
                continue
            }
            guard item.isEnabled, let action = item.action, !item.title.isEmpty else { continue }
            // The palette itself is not one of its own rows: picking it from
            // the palette would re-open the palette that is already open.
            guard action != #selector(AppDelegate.showCommandPalette(_:)) else { continue }
            let full = (path + [item.title]).joined(separator: " ▸ ")
            out.append(
                CommandPaletteItem(
                    title: item.title, path: full, shortcut: shortcutText(for: item),
                    order: out.count, menuItem: item,
                    normalizedTitle: normalize(item.title), normalizedPath: normalize(full),
                    expanded: full.contains("&")
                        ? (
                            title: normalize(item.title, readingAmpersandAsAnd: true),
                            path: normalize(full, readingAmpersandAsAnd: true)
                        )
                        : nil))
        }
    }

    // MARK: - Matching

    /// The rows a query earns, best first, capped at `limit`.
    ///
    /// An EMPTY query lists the first `limit` commands in menu order rather
    /// than running them through the scorer. Under the rules below an empty
    /// query is a prefix of every title and would score `1000 − title.count`,
    /// i.e. it would rank the app's commands by how short their names are —
    /// a meaningless list. Menu order is the honest answer to "show me what
    /// is here".
    static func matches(
        for query: String, in items: [CommandPaletteItem], limit: Int = maxRows
    ) -> [CommandPaletteItem] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return Array(items.prefix(limit)) }
        var scored: [(item: CommandPaletteItem, score: Int)] = []
        for item in items {
            var best = score(
                query: needle, title: item.normalizedTitle, path: item.normalizedPath)
            // The `&`-as-"and" spelling, for the handful of titles that have
            // one: the better of the two scores wins, so neither spelling
            // costs the other a rank.
            if let expanded = item.expanded,
               let alternate = score(
                query: needle, title: expanded.title, path: expanded.path)
            {
                best = max(best ?? alternate, alternate)
            }
            guard let score = best else { continue }
            scored.append((item: item, score: score))
        }
        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            // A shorter title matched by the same amount is the more specific
            // command ("Crop" over "Crop to Selection"), and menu order is the
            // last word so the ordering is total and stable.
            if left.item.normalizedTitle.count != right.item.normalizedTitle.count {
                return left.item.normalizedTitle.count < right.item.normalizedTitle.count
            }
            return left.item.order < right.item.order
        }
        return scored.prefix(limit).map { $0.item }
    }

    /// The score for one candidate, or nil when it does not match at all.
    ///
    /// All three arguments are already `normalize`d — that is what makes this
    /// a pure function over strings and what keeps a keystroke cheap.
    ///
    /// The four bands, strongest first:
    ///
    /// | Rank | Rule | Score |
    /// |---|---|---|
    /// | 1 | the query STARTS the title | `1000 − title.count` |
    /// | 2 | the query is inside the title | `800 − offset` |
    /// | 3 | its letters appear in order in the title | `500 − slack − first` |
    /// | 4 | …in order in the full path | `200 − slack` |
    ///
    /// where `slack` is `span − query.count`: how much filler the letters had
    /// to jump over.
    ///
    /// The bands are 200 apart so a weaker kind of match essentially never
    /// outranks a stronger one; the arithmetic inside a band is what orders
    /// it — a shorter title wins a prefix tie ("Crop" before "Crop to
    /// Selection"), an earlier hit wins a substring tie, and a tighter, earlier
    /// run of letters wins a subsequence tie. They can only overlap for a
    /// pathologically long menu title, and the sort is by score either way.
    static func score(query: String, title: String, path: String) -> Int? {
        // `matches` never asks with an empty query — it lists menu order
        // instead — but a scorer that answered nil for one would be lying:
        // everything matches nothing.
        guard !query.isEmpty else { return 0 }
        let needle = Array(query)
        let titleChars = Array(title)
        if title.hasPrefix(query) { return 1000 - titleChars.count }
        if let offset = firstOccurrence(of: needle, in: titleChars) { return 800 - offset }
        if let run = subsequence(of: needle, in: titleChars) {
            return 500 - (run.span - needle.count) - run.first
        }
        if let run = subsequence(of: needle, in: Array(path)) {
            return 200 - (run.span - needle.count)
        }
        return nil
    }

    /// Lower-cased, whitespace removed, and the three characters menus use as
    /// punctuation rather than as words stripped: the `…` that marks a dialog,
    /// the `▸` this file joins paths with, and the `&` of "Black & White",
    /// which turns a query of `black & white` into `blackwhite`.
    ///
    /// `readingAmpersandAsAnd` writes the word instead of dropping the sign,
    /// which is the SECOND candidate a `&` title is indexed under
    /// (`CommandPaletteItem.expanded`) so that `black and white` — the way
    /// the command is spoken — finds it too. A query is always normalised
    /// the plain way: a typed `&` and a typed "and" then land on the two
    /// candidates respectively, and each finds its own.
    static func normalize(_ text: String, readingAmpersandAsAnd: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text.lowercased() where !character.isWhitespace {
            if character == "&" {
                if readingAmpersandAsAnd { out += "and" }
                continue
            }
            guard !stripped.contains(character) else { continue }
            out.append(character)
        }
        return out
    }

    private static let stripped: Set<Character> = ["…", "▸", "&"]

    /// The first index at which `needle` appears contiguously in `haystack`,
    /// or nil. Naive on purpose: the whole menu is a few hundred titles of a
    /// few dozen characters, so the simple loop is both fast enough and
    /// readable.
    private static func firstOccurrence(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// Where `needle`'s characters appear IN ORDER inside `haystack`: the
    /// index of the first one and how many characters the run spans.
    ///
    /// Greedy from the left, so it reports the EARLIEST match rather than the
    /// tightest one. That is deterministic, is one pass, and is what the
    /// scoring wants anyway — an early match is the one a reader was typing
    /// towards.
    private static func subsequence(
        of needle: [Character], in haystack: [Character]
    ) -> (first: Int, span: Int)? {
        guard !needle.isEmpty else { return nil }
        var matched = 0
        var first = -1
        var last = -1
        for (index, character) in haystack.enumerated() where character == needle[matched] {
            if first < 0 { first = index }
            matched += 1
            if matched == needle.count {
                last = index
                break
            }
        }
        guard matched == needle.count, first >= 0 else { return nil }
        return (first: first, span: last - first + 1)
    }

    // MARK: - Key equivalents

    /// A menu item's key equivalent the way the menu itself draws it, so the
    /// palette teaches the shortcut while it runs the command.
    static func shortcutText(for item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        // AppKit takes an UPPERCASE key equivalent as implying Shift even when
        // the mask does not say so, and the menu draws ⇧ for it; matching that
        // keeps the palette's hint identical to the menu's.
        let uppercased = key.count == 1 && (key.first?.isUppercase ?? false)
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) || uppercased { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + displayKey(key)
    }

    /// The printable name of a key equivalent character. The named ones are
    /// the keys this app actually binds (⌫ for Clear, the arrows, Return and
    /// Escape); anything else is a letter or a symbol and prints as itself.
    private static func displayKey(_ key: String) -> String {
        switch key {
        case "\u{8}", "\u{7f}": return "⌫"
        case "\u{1b}": return "⎋"
        case "\r", "\n": return "↩"
        case "\t": return "⇥"
        case " ": return "Space"
        case "\u{f700}": return "↑"
        case "\u{f701}": return "↓"
        case "\u{f702}": return "←"
        case "\u{f703}": return "→"
        default: return key.uppercased()
        }
    }
}
