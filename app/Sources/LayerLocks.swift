import Foundation

/// A layer's lock flags, as an `OptionSet` over the core's `RzLockFlags`
/// bits (`doc_lock.rs` is where the meaning lives; this side only names and
/// displays them).
///
/// What each one does, restated here because the refusal sentences below
/// have to be true:
///
/// - **transparency** — the layer's ALPHA CHANNEL is frozen. A stroke takes
///   the new colour at full strength and the layer's original alpha is
///   restored afterwards, so an eraser cannot punch a hole and paint cannot
///   spill outside the existing shape. It does NOT block a transform: a
///   transform resamples the whole buffer including its alpha, so a frozen
///   alpha has no meaning there.
/// - **pixels** — every pixel edit is refused. Mask edits are not: Photoshop
///   lets a pixel-locked layer's mask be painted, and so does this build.
/// - **position** — moves, offsets, transforms and perspective are refused.
///   Moving a GROUP checks every descendant's position bit too, because
///   moving the group moves them.
/// - **all three together** — additionally freezes the MASK. That is the one
///   extra meaning "Lock All" carries beyond the union of the three.
///
/// Nothing here blocks delete, duplicate, reorder, group, rename, opacity,
/// blend mode, visibility or styles: Photoshop does not block those either,
/// and blocking them would make a locked layer unmanageable.
struct LockFlags: OptionSet, Equatable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        // Bits 3..31 are reserved; mask them off wherever a value enters, the
        // same way the core's setter and its `.rz` reader do.
        self.rawValue = rawValue & LockFlags.allBits
    }

    static let transparency = LockFlags(rawValue: RZ_LOCK_TRANSPARENCY.rawValue)
    static let pixels = LockFlags(rawValue: RZ_LOCK_PIXELS.rawValue)
    static let position = LockFlags(rawValue: RZ_LOCK_POSITION.rawValue)

    /// "Lock All" — spelled the way PSD's `lspf` spells it, as the three bits
    /// together rather than a fourth bit of its own.
    static let all: LockFlags = [.transparency, .pixels, .position]

    private static let allBits = RZ_LOCK_ALL.rawValue

    /// The agent's vocabulary, in the order `set_layer_lock` publishes it.
    /// One table, so the tool's schema, its reply and the menu can never
    /// disagree about a name.
    static let named: [(name: String, flag: LockFlags)] = [
        ("transparency", .transparency), ("pixels", .pixels), ("position", .position),
    ]

    /// The set's names, ascending by bit — `["transparency", "pixels"]`.
    var names: [String] { Self.named.filter { contains($0.flag) }.map { $0.name } }

    /// Menu- and alert-facing wording for ONE flag.
    var displayName: String {
        if self == .all { return "Lock All" }
        switch self {
        case .transparency: return "Transparency"
        case .pixels: return "Pixels"
        case .position: return "Position"
        default: return names.joined(separator: ", ")
        }
    }

    /// Why an edit was refused, naming the lock that stopped it — the whole
    /// point of asking the core which bits blocked rather than just seeing a
    /// NULL. `blocking` is what `lockBlockingFlags` answered.
    static func refusal(layerName: String, blocking: LockFlags) -> String {
        if blocking == .all {
            return "Layer “\(layerName)” is locked (Lock All)."
        }
        if blocking.contains(.pixels) {
            return "Layer “\(layerName)” has its pixels locked."
        }
        if blocking.contains(.position) {
            return "Layer “\(layerName)” has its position locked."
        }
        if blocking.contains(.transparency) {
            return "Layer “\(layerName)” has its transparency locked."
        }
        return "Layer “\(layerName)” is locked."
    }
}

extension RasterDocument {
    /// Entry `idx`'s locks as an `OptionSet`.
    func lockFlags(_ idx: Int) -> LockFlags { LockFlags(rawValue: layerLocks(idx)) }

    /// Which of entry `idx`'s locks would block an edit of `kind` — empty
    /// when the edit is allowed. The core refuses regardless of whether
    /// anyone asks; this exists so a refusal can NAME the lock.
    func lockBlockingFlags(_ idx: Int, kind: RzEditKind) -> LockFlags {
        LockFlags(rawValue: lockBlocking(idx, kind: kind))
    }

    /// Sets entry `idx`'s locks. Pure, like every other core op: nil when
    /// the entry already carries exactly these flags.
    func withLockFlags(_ idx: Int, _ locks: LockFlags) -> RasterDocument? {
        withLayerLocks(idx, locks.rawValue)
    }
}
