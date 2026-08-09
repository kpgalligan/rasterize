import AppKit

/// The Balopy overlap motif: three multiply-blended circles — forest upper
/// left, butter upper right, coral hanging below center. The app's only
/// decorative use of the motif.
private final class OverlapMotifView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 96) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setBlendMode(.multiply)
        // Geometry from the design system's logo mark (120x120 box, r=31
        // circles), scaled into 132x96 with the same relative placement.
        let scale: CGFloat = 96.0 / 120.0 * 1.1
        let radius = 31 * scale
        let centers = [
            (DS.forest, CGPoint(x: 45, y: 48)),
            (DS.butter, CGPoint(x: 75, y: 48)),
            (DS.coral, CGPoint(x: 60, y: 76)),
        ]
        let offsetX = (bounds.width - 120 * scale) / 2
        for (color, center) in centers {
            color.setFill()
            let point = CGPoint(
                x: offsetX + center.x * scale,
                y: bounds.height - center.y * scale)
            let rect = CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2)
            context.fillEllipse(in: rect)
        }
    }
}

/// The no-document window (design proposal 4): shown when the app is
/// frontmost with nothing open, replacing the bare open panel. Accepts
/// dropped files via FileDropView and closes as soon as a document opens.
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Rasterize"
        window.center()
        super.init(window: window)

        let root = FileDropView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        root.wantsLayer = true

        let motif = OverlapMotifView(frame: .zero)
        motif.translatesAutoresizingMaskIntoConstraints = false

        let headline = NSTextField(labelWithString: "Edit anything. Natively.")
        headline.translatesAutoresizingMaskIntoConstraints = false
        headline.font = DS.display(42)
        headline.textColor = DS.textStrong
        headline.alignment = .center

        let paragraph = NSTextField(
            wrappingLabelWithString:
                "Rasterize does not create blank canvases — every document "
                + "starts from pixels you already have.")
        paragraph.translatesAutoresizingMaskIntoConstraints = false
        paragraph.font = DS.sans(15)
        paragraph.textColor = DS.textMuted
        paragraph.alignment = .center
        paragraph.isEditable = false
        paragraph.preferredMaxLayoutWidth = 400

        let openButton = StickerButton(
            title: "Open…", style: .primary, target: nil,
            action: #selector(NSDocumentController.openDocument(_:)))
        let clipboardButton = StickerButton(
            title: "New from Clipboard", style: .secondary, target: nil,
            action: #selector(AppDelegate.newFromClipboard(_:)))
        let buttons = NSStackView(views: [openButton, clipboardButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let formats = NSTextField(
            labelWithString: "PNG · JPEG · PSD (layered) · TIFF · BMP · GIF · WebP · RZ")
        formats.translatesAutoresizingMaskIntoConstraints = false
        formats.font = DS.mono(11)
        formats.textColor = DS.textFaint
        formats.alignment = .center

        let stack = NSStackView(views: [motif, headline, paragraph, buttons, formats])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.setCustomSpacing(24, after: motif)
        stack.setCustomSpacing(10, after: headline)
        stack.setCustomSpacing(26, after: paragraph)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -8),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        window.contentView = root
        applyBackground()

        // Close as soon as any document window becomes main; the welcome
        // window returns via applicationShouldOpenUntitledFile when the app
        // reactivates with nothing open.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WelcomeWindowController does not support NSCoder")
    }

    private func applyBackground() {
        window?.backgroundColor = DS.chromeBackground
        window?.contentView?.layer?.backgroundColor = DS.chromeBackground.cgColor
    }

    @objc private func windowBecameMain(_ note: Notification) {
        guard let main = note.object as? NSWindow, main !== window,
              main.windowController?.document != nil
        else { return }
        window?.close()
    }

    func show() {
        applyBackground()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
