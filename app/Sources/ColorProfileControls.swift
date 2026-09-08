import AppKit
import UniformTypeIdentifiers

/// A profile the user picked in one of the Image > Mode sheets: one of the
/// two this build writes for itself, or bytes read off disk.
///
/// It carries the BYTES, not a name or an index, because the bytes are what
/// `assigningProfile`/`convertingToProfile` take and what an export embeds —
/// a name would have to be resolved back into bytes somewhere, and that
/// somewhere is exactly where the two sheets would drift apart.
enum ProfileChoice {
    case builtin(WorkingSpace)
    /// Loaded bytes plus the name to show for them: the profile's own `desc`
    /// text as the core reads it, so a document tagged from a file names
    /// itself the same way the status bar and MCP do.
    case file(Data, String)

    /// The ICC bytes to assign, or to convert into.
    var data: Data {
        switch self {
        case .builtin(let space): return space.profileData
        case .file(let data, _): return data
        }
    }

    /// What to call it on screen. The built-ins use the short menu name
    /// ("sRGB", "Display P3") rather than the `desc` text the core writes
    /// into the blob ("sRGB IEC61966-2.1"), because that is the name the
    /// Working Space menu already shows for the same two profiles.
    var name: String {
        switch self {
        case .builtin(let space): return space.displayName
        case .file(_, let name): return name
        }
    }

    /// What the core makes of these bytes. It re-inspects — a header and
    /// tag-table walk over a few kilobytes — so ask it when the SELECTION
    /// changes and keep the answer; it is not a per-redraw accessor.
    var kind: RasterProfileKind { RasterProfile.inspect(data).kind }
}

/// The profile popup the Assign and Convert sheets share, and the file
/// loading behind its last row. Kept here rather than in either sheet — the
/// `ChannelMathControls` precedent — so the two dialogs cannot offer
/// different profiles or refuse a file for different reasons.
enum ColorProfileControls {
    /// Tags on the popup's items. A built-in carries its index in
    /// `WorkingSpace.allCases`, which is why the three sentinels are
    /// negative: the index is the tag, so nothing has to stay in step with a
    /// parallel list.
    private static let loadTag = -1
    private static let currentTag = -2
    private static let loadedTag = -3

    /// The popup's width cap, the Save Selection sheet's number for the same
    /// problem: a row here can be an arbitrary embedded profile name, and
    /// the 420 pt card less its 2 × 22 insets, the 106 pt label column and
    /// the grid's 12 pt column spacing leaves 258 pt. Capping at 250 rather
    /// than fixing a width lets a long name truncate instead of widening the
    /// card, while the two short built-ins keep a compact popup.
    private static let popupWidth: CGFloat = 250

    /// The largest profile the panel will read. It is the core's own cap —
    /// `rz_doc_assign_profile` refuses a payload over 16 MiB, the same limit
    /// the .rz writer puts on a stored blob — so a file this side accepts is
    /// one the document can actually hold and save. Real profiles are
    /// kilobytes; even a fat LUT-based one is a few megabytes.
    private static let maxProfileBytes = 16 * 1024 * 1024

    /// Fills a profile popup: the two built-ins, the document's OWN profile
    /// when it is neither of them, and "Load from file…" last.
    ///
    /// The document's own profile is a row so the popup can OPEN on it. A
    /// sheet that started somewhere else would put a real change one click
    /// away and give the user no way back to where the document already is —
    /// and both sheets read "is this still the current profile?" off the
    /// selection to decide whether Apply does anything at all.
    ///
    /// Installs the popup's width constraint, so call it exactly once per
    /// popup, from `loadView` (the `ChannelMathControls.fill…` rule).
    static func fillProfiles(_ popup: NSPopUpButton, current: Data?, currentName: String) {
        let menu = NSMenu()
        for (tag, space) in WorkingSpace.allCases.enumerated() {
            let item = NSMenuItem(title: space.displayName, action: nil, keyEquivalent: "")
            item.tag = tag
            menu.addItem(item)
        }
        // Which row the document is already on, asked once: a built-in it
        // matches byte for byte, or a row of its own.
        let builtinIndex = current.flatMap { bytes in
            WorkingSpace.allCases.firstIndex { $0.profileData == bytes }
        }
        var currentItem: NSMenuItem?
        if let current = current, !current.isEmpty, builtinIndex == nil {
            menu.addItem(.separator())
            let item = NSMenuItem(
                // A storable profile always names itself, so the fallback is
                // for a document whose name read back empty rather than for
                // any expected case.
                title: currentName.isEmpty ? "Embedded profile" : currentName,
                action: nil, keyEquivalent: "")
            item.tag = currentTag
            item.representedObject = current
            menu.addItem(item)
            currentItem = item
        }
        menu.addItem(.separator())
        let load = NSMenuItem(title: "Load from file…", action: nil, keyEquivalent: "")
        load.tag = loadTag
        menu.addItem(load)

        popup.menu = menu
        if let currentItem = currentItem {
            popup.select(currentItem)
        } else {
            // A built-in match selects its row; no profile at all — a
            // document always has one, so that is the read-failed path —
            // starts on sRGB, the working space's own default.
            popup.selectItem(withTag: builtinIndex ?? 0)
        }
        popup.font = DS.sans(13)
        popup.widthAnchor.constraint(lessThanOrEqualToConstant: popupWidth).isActive = true
    }

    /// The profile a popup names, or nil while its "Load from file…" row is
    /// the selection — that row is a verb, and `resolveSelection` is what
    /// turns it back into a value.
    static func choice(_ popup: NSPopUpButton) -> ProfileChoice? {
        guard let item = popup.selectedItem else { return nil }
        return choice(for: item)
    }

    /// What the popup names now, running the open panel first when the user
    /// picked "Load from file…".
    ///
    /// `completion` runs exactly once on the main thread: synchronously for
    /// a row that already carries its bytes, and after the panel closes for
    /// the Load row. A cancelled panel, an unreadable file and a refused
    /// profile all put the popup back on `previous` and answer it, so a
    /// sheet's state can never disagree with what its popup shows.
    static func resolveSelection(
        _ popup: NSPopUpButton, presenter: NSViewController, previous: ProfileChoice,
        completion: @escaping (ProfileChoice) -> Void
    ) {
        if let picked = choice(popup) {
            completion(picked)
            return
        }
        guard let window = presenter.view.window else {
            select(previous, in: popup)
            completion(previous)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an ICC colour profile."
        panel.prompt = "Load"
        panel.allowedContentTypes = profileContentTypes
        // A sheet on the sheet's own window: the profile sheets are modal to
        // the document window, and the panel belongs to the dialog that
        // opened it, not to the document behind it.
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url,
                  let loaded = load(url, presenter: presenter)
            else {
                select(previous, in: popup)
                completion(previous)
                return
            }
            install(loaded, in: popup)
            completion(loaded)
        }
    }

    /// The wrapping 12 pt muted line the two sheets carry under their grid.
    /// `makeSheetView`'s own `hint:` is fixed when the card is built, and
    /// both of these sentences change while the sheet is open — which
    /// profile is selected changes what Apply would do, and the sheets say
    /// so rather than leaving the user to infer it.
    static func noteLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = DS.sans(12)
        label.textColor = DS.textMuted
        label.isEditable = false
        label.isSelectable = false
        label.preferredMaxLayoutWidth = sheetWidth - sheetInset * 2
        return label
    }

    /// What the OPEN did to a document's colour, as a sentence — the
    /// host-side `profileAdoption`, which describes the open and is never
    /// updated by a later Assign or Convert.
    static func adoptionSentence(_ outcome: RasterAdoptOutcome) -> String {
        switch outcome {
        case .unchanged:
            return "Opening it changed nothing about its colour."
        case .converted:
            return "Its pixels were converted into the working space when it opened."
        case .keptUnconvertible:
            return "Its embedded profile was kept when it opened, but Rasterize cannot "
                + "convert with it, so no pixel was touched."
        }
    }

    /// Whether the profile in `bytes` describes the space `current` already
    /// names. Byte equality is only the cheap half: a different blob can
    /// describe the same space, which is exactly what makes an ordinary
    /// camera JPEG's "assign sRGB" or "convert to sRGB" a no-op — the
    /// HP/IEC blob most files embed is 3144 bytes against the built-in's
    /// 2568. Asked of the CORE, which is the only thing that can answer it,
    /// and shared by both sheets so they cannot give the same profile two
    /// different verdicts.
    static func describesCurrentSpace(_ bytes: Data, current: Data) -> Bool {
        bytes == current || RasterProfile.describesSameSpace(bytes, current)
    }

    // MARK: - What Convert actually leaves looking the same

    /// True when this document holds a layer whose APPEARANCE is computed
    /// from the pixel numbers rather than carried by them — a non-Normal
    /// blend mode, an adjustment layer, or a layer style with a non-Normal
    /// effect blend or a Blend If range.
    ///
    /// Convert to Profile changes every layer's numbers to keep each layer
    /// looking the same, which is correct and is what Photoshop does. But
    /// blend math, an adjustment's curve and a Blend If threshold are all
    /// evaluated ON those numbers, in the document's own space, so on such a
    /// stack the composite genuinely moves — measured at up to 41 codes on
    /// an ordinary Multiply layer. The behaviour is right; saying "the
    /// picture looks the same" about it is not, so the sheet and the MCP
    /// mirror ask this and say which case the document is in.
    static func appearanceDependsOnNumbers(_ doc: RasterDocument) -> Bool {
        (0..<doc.layerCount).contains { i in
            if let info = doc.layerInfo(i), info.blendMode != RZ_BLEND_NORMAL { return true }
            if doc.layerIsAdjustment(i) { return true }
            return styleBlendsWithPixels(doc.layerStyle(i))
        }
    }

    /// The sentence that follows "every layer's pixels move": what stays and
    /// what does not.
    static func convertAppearanceSentence(_ doc: RasterDocument) -> String {
        let clipping = "Colours outside the new space are the ones that move, clipped into it."
        guard appearanceDependsOnNumbers(doc) else {
            return "Each layer keeps its appearance. " + clipping
        }
        return "Each layer's own appearance is preserved, but this document has layers whose "
            + "result is computed FROM the numbers — a non-Normal blend mode, an adjustment "
            + "layer or a style effect that blends — and those are evaluated in the new space, "
            + "so the composite will change visibly. " + clipping
    }

    /// Whether a layer style's canonical JSON describes something that
    /// blends with the pixels below it: any enabled effect at a blend mode
    /// other than Normal, or a Blend If range. Parsed rather than
    /// string-matched — the core is the authority on the schema
    /// (`core/src/style.rs`), and every effect writes its mode under a key
    /// ending in `blend`.
    private static func styleBlendsWithPixels(_ json: String?) -> Bool {
        guard let json = json, let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        if root["blend_if"] is [String: Any] { return true }
        guard let effects = root["effects"] as? [[String: Any]] else { return false }
        return effects.contains { effect in
            guard effect["enabled"] as? Bool ?? true else { return false }
            return effect.contains { key, value in
                key.hasSuffix("blend") && (value as? String) != "normal"
            }
        }
    }

    // MARK: - Loading a profile from disk

    /// The types the panel offers. `com.apple.colorsync-profile` is the
    /// system type both `.icc` and `.icm` conform to; the two extensions are
    /// asked for as well so a file the system has not classified still
    /// appears.
    private static let profileContentTypes: [UTType] = {
        var types: [UTType] = []
        for candidate in [
            UTType("com.apple.colorsync-profile"),
            UTType(filenameExtension: "icc"),
            UTType(filenameExtension: "icm"),
        ] {
            guard let type = candidate, !types.contains(type) else { continue }
            types.append(type)
        }
        return types
    }()

    /// The file as a choice, or nil with the reason already on screen.
    ///
    /// The bytes are inspected HERE, before the core is asked to store them,
    /// for the reason `ChannelBudget` exists: `assigningProfile` answers a
    /// bare nil and `applyEdit` turns that into a beep, which cannot say
    /// whether the file was a CMYK profile, a JPEG, or the profile the
    /// document already carries.
    private static func load(_ url: URL, presenter: NSViewController) -> ProfileChoice? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxProfileBytes else {
            presenter.presentColorProfileAlert(
                "“\(url.lastPathComponent)” is "
                    + String(format: "%.1f", Double(size) / (1024 * 1024))
                    + " MB. A Rasterize document can carry a profile of at most 16 MB, so "
                    + "this one could not be saved with the file.")
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            presenter.presentColorProfileAlert("“\(url.lastPathComponent)” could not be read.")
            return nil
        }
        let info = RasterProfile.inspect(data)
        switch info.kind {
        case .notICC:
            presenter.presentColorProfileAlert(
                "“\(url.lastPathComponent)” is not an ICC colour profile.")
            return nil
        case .notRGB:
            presenter.presentColorProfileAlert(
                "“\(info.name)” is not an RGB profile — Rasterize documents are RGB, so Gray, "
                    + "CMYK and Lab profiles cannot be assigned.")
            return nil
        case .notImageProfile:
            // A device-link, abstract or named-colour profile: RGB numbers,
            // but a description of a TRANSFORM rather than of the space a
            // picture's numbers live in. macOS ships one
            // (WebSafeColors.icc), and tagging a document with it left
            // CoreGraphics no way to convert out of it, so the canvas, the
            // thumbnails and every export drew as an empty image.
            presenter.presentColorProfileAlert(
                "“\(info.name)” describes a colour transform rather than a colour space — it "
                    + "is a device-link, abstract or named-colour profile, so there is no way "
                    + "to interpret a document's pixels in it.")
            return nil
        case .rgbUnconvertible, .rgbMatrix:
            // A LUT-based RGB profile is accepted here: it can be assigned,
            // displayed and re-embedded on export. Only Convert refuses it,
            // and its sheet says so in the one place that can explain why.
            return .file(data, info.name.isEmpty ? url.lastPathComponent : info.name)
        }
    }

    // MARK: - Menu bookkeeping

    private static func choice(for item: NSMenuItem) -> ProfileChoice? {
        guard !item.isSeparatorItem else { return nil }
        switch item.tag {
        case loadTag:
            return nil
        case currentTag, loadedTag:
            guard let data = item.representedObject as? Data else { return nil }
            return .file(data, item.title)
        default:
            let spaces = WorkingSpace.allCases
            guard spaces.indices.contains(item.tag) else { return nil }
            return .builtin(spaces[item.tag])
        }
    }

    /// Puts a loaded profile in the menu and selects it, replacing any
    /// previously loaded one — a second Load means "instead of", not "as
    /// well as", and the document's own row stays put either way so the user
    /// can always get back to it.
    private static func install(_ choice: ProfileChoice, in popup: NSPopUpButton) {
        guard case .file(let data, let name) = choice, let menu = popup.menu else { return }
        if let existing = menu.item(withTag: loadedTag) {
            existing.title = name
            existing.representedObject = data
            popup.select(existing)
            return
        }
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.tag = loadedTag
        item.representedObject = data
        // Above the separator that precedes "Load from file…", so the verb
        // stays last, where the user just found it.
        let separator = menu.item(withTag: loadTag).map { menu.index(of: $0) - 1 }
        menu.insertItem(item, at: max(separator ?? menu.numberOfItems, 0))
        popup.select(item)
    }

    /// Puts the popup back on a choice it already holds. Matched by BYTES,
    /// so restoring the previous selection after a cancelled panel lands on
    /// the same row whether it was a built-in, the document's own profile or
    /// an earlier load.
    private static func select(_ wanted: ProfileChoice, in popup: NSPopUpButton) {
        guard let menu = popup.menu else { return }
        let bytes = wanted.data
        guard let match = menu.items.first(where: { choice(for: $0)?.data == bytes }) else {
            return
        }
        popup.select(match)
    }
}

extension NSViewController {
    /// A profile refusal, said out loud, in the shape the channel budget
    /// already uses: a sheet on the controller's own window, or a modal
    /// alert when it has none.
    func presentColorProfileAlert(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Cannot Use That Profile"
        alert.informativeText = reason
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
