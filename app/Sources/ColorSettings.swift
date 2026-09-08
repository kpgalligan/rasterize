import AppKit

/// The app-wide COLOUR WORKING SPACE: the profile a newly opened flat file
/// is converted to.
///
/// It is a preference, not document state — a document's own profile travels
/// in the file and in the `.rz`, and Assign/Convert Profile change that
/// document alone. Changing the working space affects FUTURE opens only.
///
/// One consequence is worth stating plainly, because it is the price of
/// having exactly one rule: a file with NO profile is assumed sRGB (that is
/// what every reader does), and once its numbers are sRGB numbers, honouring
/// the working space means converting them. So under Display P3 an untagged
/// file is converted on open, and opening one and immediately saving it back
/// does not reproduce the input bytes. Under the default sRGB working space
/// that branch is a no-op and never fires.
enum WorkingSpace: String, CaseIterable {
    case sRGB = "srgb"
    case displayP3 = "displayP3"

    var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        }
    }

    var builtin: RasterBuiltinProfile {
        switch self {
        case .sRGB: return .sRGB
        case .displayP3: return .displayP3
        }
    }

    /// The ICC bytes this build writes for the space — the same blob an
    /// export embeds, so "the working space" and "what lands in the file"
    /// are the same object.
    var profileData: Data { RasterProfile.builtin(builtin) }

    /// The space to DECODE into when the platform is doing the decoding and
    /// there is no source profile to preserve (a Live Photo frame).
    var cgSpace: CGColorSpace { ColorProfile.space(for: profileData) }
}

/// Where the working space is stored and read. A bare `UserDefaults` key,
/// not `ToolOptionsStore`: this is one app-wide enum, not a per-tool value,
/// and it is read on the open path where no tool is involved.
enum ColorSettings {
    static let workingSpaceKey = "ColorWorkingSpace"

    /// The current working space; `.sRGB` when unset or when the stored
    /// string is not one this build knows (a downgrade must not brick the
    /// open path).
    static var workingSpace: WorkingSpace {
        get {
            let raw = UserDefaults.standard.string(forKey: workingSpaceKey) ?? ""
            return WorkingSpace(rawValue: raw) ?? .sRGB
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: workingSpaceKey) }
    }
}
