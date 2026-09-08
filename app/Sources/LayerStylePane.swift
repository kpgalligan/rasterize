import AppKit

/// The Layer Style sheet's pane contract (LayerStyleSheetController hosts
/// one pane at a time) and the row builders every pane composes its grid
/// from, so the nine effect panes and the Blending Options pane keep the
/// sheet conventions — 106 pt trailing label column, 180 pt sliders, mono 12
/// readouts 52 pt wide, rowSpacing 10 / columnSpacing 12 — without each
/// re-deriving them. A pane never touches the document: it edits a value
/// through its binding, and the sheet owns preview and commit.

/// One pane of the Layer Style sheet: edits ONE effect (or the blending
/// options) through its binding and calls the binding's `set` on every
/// control change; the sheet re-previews and refreshes the checklist.
protocol LayerStylePane: AnyObject {
    var view: NSView { get }
    /// Re-reads the bound value into the controls (Reset, checklist toggles,
    /// a global-light edit made from another pane).
    func reload()
}

/// Read/write access to one value inside the sheet's `LayerStyle`.
final class EffectBinding<Value> {
    private let get: () -> Value
    private let set: (Value) -> Void

    init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get
        self.set = set
    }

    func read() -> Value { get() }

    func write(_ value: Value) { set(value) }

    /// Read, mutate, write — one control change.
    func update(_ mutate: (inout Value) -> Void) {
        var value = get()
        mutate(&value)
        set(value)
    }
}

/// What every pane may need beyond its own effect.
struct LayerStylePaneContext {
    /// The document's global light — edited by the panes whose effect has
    /// `use_global_light` on (their Angle/Altitude sliders write here, so
    /// the preview follows a global-light-only edit).
    let globalLight: EffectBinding<GlobalLight>
    let canvasSize: CGSize
}

// MARK: - Rows

/// How a row's cells sit in the grid: label + control cells, the control
/// cells merged (a checkbox with a long title must not widen the slider
/// column), or one cell across every column (a note).
enum PaneRowSpan {
    case none
    case controls
    case all
}

/// One grid row: its cells (label column first) and a reload from its
/// getter.
protocol PaneRow: AnyObject {
    var views: [NSView] { get }
    var span: PaneRowSpan { get }
    func reload()
}

extension PaneRow {
    var span: PaneRowSpan { .none }
}

enum PaneRows {
    static let labelColumnWidth: CGFloat = 106
    static let sliderWidth: CGFloat = 180
    static let readoutWidth: CGFloat = 52
    /// Notes wrap inside the pane host (404 pt) with a little air.
    static let noteWidth: CGFloat = 380

    /// The rows as one grid in the sheet conventions. NSGridView pads short
    /// rows with empty cells, which is what lets a checkbox or note row
    /// merge across the columns the slider rows define.
    static func grid(_ rows: [PaneRow]) -> NSGridView {
        let grid = NSGridView(views: rows.map { $0.views })
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = labelColumnWidth
        let columns = grid.numberOfColumns
        for (index, row) in rows.enumerated() {
            switch row.span {
            case .none:
                continue
            case .controls:
                guard columns > 2 else { continue }
                grid.mergeCells(
                    inHorizontalRange: NSRange(location: 1, length: columns - 1),
                    verticalRange: NSRange(location: index, length: 1))
            case .all:
                grid.mergeCells(
                    inHorizontalRange: NSRange(location: 0, length: columns),
                    verticalRange: NSRange(location: index, length: 1))
                grid.cell(atColumnIndex: 0, rowIndex: index).xPlacement = .leading
            }
        }
        return grid
    }

    static func slider(
        _ label: String, min: Double, max: Double, integer: Bool = false,
        format: @escaping (Double) -> String,
        get: @escaping () -> Double, set: @escaping (Double) -> Void
    ) -> PaneSliderRow {
        PaneSliderRow(
            label: label, min: min, max: max, integer: integer, format: format, get: get, set: set)
    }

    /// 0…`max` whole pixels. The slider's ceiling is the dialog's; the
    /// schema may allow more (a 1000 px distance set over MCP shows in the
    /// readout and is only rewritten when the slider moves).
    static func pixels(
        _ label: String, max: Double, get: @escaping () -> Double,
        set: @escaping (Double) -> Void
    ) -> PaneSliderRow {
        slider(
            label, min: 0, max: max, integer: true, format: { String(format: "%.0f px", $0) },
            get: get, set: set)
    }

    /// A 0…1 model value as a whole-number percent, Photoshop's granularity.
    static func percent(
        _ label: String, get: @escaping () -> Double, set: @escaping (Double) -> Void
    ) -> PaneSliderRow {
        slider(
            label, min: 0, max: 100, integer: true, format: { String(format: "%.0f %%", $0) },
            get: { get() * 100 }, set: { set($0 / 100) })
    }

    /// -180…180 whole degrees (the core normalizes 180 to -180).
    static func angle(
        _ label: String, get: @escaping () -> Double, set: @escaping (Double) -> Void
    ) -> PaneSliderRow {
        slider(
            label, min: -180, max: 180, integer: true, format: { String(format: "%.0f°", $0) },
            get: get, set: set)
    }

    /// The 27 blend modes grouped like the layers panel's popup (tags are
    /// the raw values); the bound value is the style JSON's snake_case name.
    static func blendPopup(
        _ label: String = "Blend Mode:", get: @escaping () -> String,
        set: @escaping (String) -> Void
    ) -> PanePopupRow {
        let menu = NSMenu()
        for (groupIndex, group) in RzBlendMode.blendModeGroups.enumerated() {
            if groupIndex > 0 {
                menu.addItem(.separator())
            }
            for (mode, title) in group {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = Int(mode.rawValue)
                item.representedObject = LayerStyleBlend.name(for: mode)
                menu.addItem(item)
            }
        }
        return PanePopupRow(label: label, menu: menu, get: get, set: set)
    }

    /// A plain enum popup: `titles` shown, `values` (the JSON strings) bound.
    static func popup(
        _ label: String, titles: [String], values: [String], get: @escaping () -> String,
        set: @escaping (String) -> Void
    ) -> PanePopupRow {
        let menu = NSMenu()
        for (title, value) in zip(titles, values) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = value
            menu.addItem(item)
        }
        return PanePopupRow(label: label, menu: menu, get: get, set: set)
    }

    static func checkbox(
        _ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void
    ) -> PaneCheckboxRow {
        PaneCheckboxRow(title: title, get: get, set: set)
    }

    /// A colour swatch (the options bar's, bound through LayerStyleColor):
    /// clicking it aims the shared colour panel at the bound hex string.
    static func color(
        _ label: String, get: @escaping () -> String, set: @escaping (String) -> Void
    ) -> PaneColorRow {
        PaneColorRow(label: label, get: get, set: set)
    }

    /// A wrapping muted note across both columns.
    static func note(_ text: String) -> PaneNoteRow {
        PaneNoteRow(text: text)
    }
}

/// Label, 180 pt continuous slider, 52 pt mono readout. `integer` rounds the
/// slider's value before it is shown or written, so the model only ever
/// holds whole pixels / percents / degrees from the dialog.
final class PaneSliderRow: NSObject, PaneRow {
    private let label: NSTextField
    private let slider: NSSlider
    private let readout = NSTextField(labelWithString: "")
    private let integer: Bool
    private let format: (Double) -> String
    private let get: () -> Double
    private let set: (Double) -> Void

    var views: [NSView] { [label, slider, readout] }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            slider.isEnabled = newValue
            label.textColor = newValue ? DS.textStrong : DS.textFaint
            readout.textColor = newValue ? DS.textMuted : DS.textFaint
        }
    }

    init(
        label: String, min: Double, max: Double, integer: Bool,
        format: @escaping (Double) -> String, get: @escaping () -> Double,
        set: @escaping (Double) -> Void
    ) {
        self.label = fieldLabel(label)
        self.slider = NSSlider(value: get(), minValue: min, maxValue: max, target: nil, action: nil)
        self.integer = integer
        self.format = format
        self.get = get
        self.set = set
        super.init()
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed(_:))
        slider.widthAnchor.constraint(equalToConstant: PaneRows.sliderWidth).isActive = true
        readout.font = DS.mono(12)
        readout.textColor = DS.textMuted
        readout.alignment = .right
        readout.widthAnchor.constraint(equalToConstant: PaneRows.readoutWidth).isActive = true
        reload()
    }

    func reload() {
        let value = rounded(get())
        slider.doubleValue = value
        // The readout shows the model's value even when it lies past the
        // slider's range (which the slider clamps on its own).
        readout.stringValue = format(value)
    }

    @objc private func changed(_ sender: Any?) {
        let value = rounded(slider.doubleValue)
        readout.stringValue = format(value)
        set(value)
    }

    private func rounded(_ value: Double) -> Double {
        integer ? value.rounded() : value
    }
}

/// Label + popup; each item's `representedObject` is the bound string.
final class PanePopupRow: NSObject, PaneRow {
    private let label: NSTextField
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let get: () -> String
    private let set: (String) -> Void

    var views: [NSView] { [label, popup] }

    init(label: String, menu: NSMenu, get: @escaping () -> String, set: @escaping (String) -> Void) {
        self.label = fieldLabel(label)
        self.get = get
        self.set = set
        super.init()
        popup.menu = menu
        popup.font = DS.sans(13)
        popup.target = self
        popup.action = #selector(changed(_:))
        popup.widthAnchor.constraint(equalToConstant: PaneRows.sliderWidth).isActive = true
        reload()
    }

    func reload() {
        let value = get()
        guard let item = popup.itemArray.first(where: { ($0.representedObject as? String) == value })
        else { return }
        popup.select(item)
    }

    @objc private func changed(_ sender: Any?) {
        guard let value = popup.selectedItem?.representedObject as? String else { return }
        set(value)
    }
}

/// A checkbox in the control columns (the label column stays empty).
final class PaneCheckboxRow: NSObject, PaneRow {
    private let checkbox: NSButton
    private let get: () -> Bool
    private let set: (Bool) -> Void

    var views: [NSView] { [NSGridCell.emptyContentView, checkbox] }
    var span: PaneRowSpan { .controls }

    init(title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        self.checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        self.get = get
        self.set = set
        super.init()
        checkbox.font = DS.sans(13)
        checkbox.target = self
        checkbox.action = #selector(changed(_:))
        reload()
    }

    func reload() {
        checkbox.state = get() ? .on : .off
    }

    @objc private func changed(_ sender: Any?) {
        set(checkbox.state == .on)
    }
}

/// Label + the options bar's 22 pt swatch, bound to a "#rrggbb" string.
final class PaneColorRow: NSObject, PaneRow {
    private let label: NSTextField
    private let swatch: OptionSwatchControl

    var views: [NSView] { [label, swatch] }

    init(label: String, get: @escaping () -> String, set: @escaping (String) -> Void) {
        self.label = fieldLabel(label)
        self.swatch = OptionSwatchControl(
            read: { LayerStyleColor.color(fromHex: get()) ?? .black },
            write: { set(LayerStyleColor.hex($0)) },
            enabled: { true },
            onEdit: {})
        super.init()
    }

    func reload() {
        swatch.refresh()
    }
}

/// A wrapping DS.sans(12) muted note spanning every column.
final class PaneNoteRow: NSObject, PaneRow {
    private let note: NSTextField

    var views: [NSView] { [note] }
    var span: PaneRowSpan { .all }

    init(text: String) {
        note = NSTextField(wrappingLabelWithString: text)
        note.font = DS.sans(12)
        note.textColor = DS.textMuted
        note.preferredMaxLayoutWidth = PaneRows.noteWidth
        super.init()
    }

    func reload() {}
}
