import AppKit

enum HoverPreviewPreference {
    private static let key = "TexFastHoverPreviews"

    static var isEnabled: Bool {
        // Existing installations have no stored value; previews stay on until
        // the user explicitly changes this setting.
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
        NotificationCenter.default.post(name: .texFastHoverPreviewsChanged, object: nil)
    }
}

extension Notification.Name {
    static let texFastHoverPreviewsChanged = Notification.Name("texFastHoverPreviewsChanged")
}

final class SettingsViewController: NSViewController {
    private let hoverToggle = NSButton(checkboxWithTitle: "Show hover previews", target: nil, action: nil)

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Editor")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        hoverToggle.target = self
        hoverToggle.action = #selector(changeHoverPreviews(_:))
        hoverToggle.font = .systemFont(ofSize: 13, weight: .medium)

        let detail = NSTextField(wrappingLabelWithString:
            "Render formulas, images, drawings, and tables when you rest the pointer on their TeX source.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        for item in [title, hoverToggle, detail] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            hoverToggle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hoverToggle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 24),
            detail.leadingAnchor.constraint(equalTo: hoverToggle.leadingAnchor, constant: 22),
            detail.topAnchor.constraint(equalTo: hoverToggle.bottomAnchor, constant: 6),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28)
        ])
        view = root
        refresh()
    }

    func refresh() { hoverToggle.state = HoverPreviewPreference.isEnabled ? .on : .off }

    @objc private func changeHoverPreviews(_ sender: NSButton) {
        HoverPreviewPreference.setEnabled(sender.state == .on)
    }
}

final class SettingsWindowController: NSWindowController {
    let settings = SettingsViewController()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 166),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TexFast Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = settings
        window.setContentSize(NSSize(width: 480, height: 166))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
