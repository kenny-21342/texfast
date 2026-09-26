import AppKit

private final class AccentTile: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class AboutFeatureRow: NSView {
    init(symbol: String, title: String, detail: String) {
        super.init(frame: .zero)

        let tile = AccentTile()
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let description = NSTextField(labelWithString: detail)
        description.font = .systemFont(ofSize: 11)
        description.textColor = .secondaryLabelColor
        description.lineBreakMode = .byWordWrapping
        description.maximumNumberOfLines = 2

        for item in [tile, heading, description] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 40),
            tile.heightAnchor.constraint(equalToConstant: 40),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 21),
            icon.heightAnchor.constraint(equalToConstant: 21),
            heading.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 15),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor),
            description.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            description.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            description.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class AboutViewController: NSViewController {
    override func loadView() {
        let root = NSView()
        let hero = NSVisualEffectView()
        hero.material = .headerView
        hero.blendingMode = .withinWindow
        hero.state = .active

        let appIcon = NSImageView(image: NSApp.applicationIconImage)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "TexFast")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        let tagline = NSTextField(labelWithString: "Write in TeX. See the page.")
        tagline.font = .systemFont(ofSize: 15, weight: .medium)
        let summary = NSTextField(labelWithString: "Source, preview, and project tools in one native workspace.")
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor

        let section = NSTextField(labelWithString: "BUILT FOR THE EDIT LOOP")
        section.font = .systemFont(ofSize: 10, weight: .semibold)
        section.textColor = .tertiaryLabelColor
        let source = AboutFeatureRow(symbol: "arrow.left.arrow.right",
                                     title: "Stay in sync",
                                     detail: "Move between TeX source and the PDF with a click.")
        let preview = AboutFeatureRow(symbol: "bolt",
                                      title: "Preview while you write",
                                      detail: "Quick draft builds, with a two-pass final PDF on quit.")
        let terminal = AboutFeatureRow(symbol: "terminal",
                                       title: "Work beside your document",
                                       detail: "Run a project shell or coding agent in the built-in terminal.")

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .map { "Version \($0)" } ?? "Development build"
        let versionLabel = NSTextField(labelWithString: version)
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        let licenseButton = NSButton(title: "Open source licenses", target: self,
                                     action: #selector(openLicenses(_:)))
        licenseButton.isBordered = false
        licenseButton.font = .systemFont(ofSize: 11)
        licenseButton.contentTintColor = .linkColor

        let heroDivider = NSBox()
        heroDivider.boxType = .separator
        let footerDivider = NSBox()
        footerDivider.boxType = .separator

        for item in [hero, section, source, preview, terminal, footerDivider,
                     versionLabel, licenseButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        for item in [appIcon, title, tagline, summary, heroDivider] {
            item.translatesAutoresizingMaskIntoConstraints = false
            hero.addSubview(item)
        }
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: root.topAnchor),
            hero.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hero.heightAnchor.constraint(equalToConstant: 171),
            appIcon.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 36),
            appIcon.topAnchor.constraint(equalTo: hero.topAnchor, constant: 44),
            appIcon.widthAnchor.constraint(equalToConstant: 70),
            appIcon.heightAnchor.constraint(equalToConstant: 70),
            title.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 21),
            title.topAnchor.constraint(equalTo: appIcon.topAnchor, constant: -4),
            tagline.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            tagline.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.topAnchor.constraint(equalTo: tagline.bottomAnchor, constant: 9),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: hero.trailingAnchor, constant: -20),
            heroDivider.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            heroDivider.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
            heroDivider.bottomAnchor.constraint(equalTo: hero.bottomAnchor),

            section.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 36),
            section.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 27),
            source.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            source.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -36),
            source.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 16),
            source.heightAnchor.constraint(equalToConstant: 58),
            preview.leadingAnchor.constraint(equalTo: source.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: source.trailingAnchor),
            preview.topAnchor.constraint(equalTo: source.bottomAnchor, constant: 8),
            preview.heightAnchor.constraint(equalTo: source.heightAnchor),
            terminal.leadingAnchor.constraint(equalTo: source.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: source.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 8),
            terminal.heightAnchor.constraint(equalTo: source.heightAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -53),
            versionLabel.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            versionLabel.centerYAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 27),
            licenseButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -33),
            licenseButton.centerYAnchor.constraint(equalTo: versionLabel.centerYAnchor)
        ])
        view = root
    }

    @objc private func openLicenses(_ sender: Any?) {
        guard let url = Bundle.main.url(forResource: "SwiftTerm-LICENSE", withExtension: "txt") else { return }
        NSWorkspace.shared.open(url)
    }
}

final class AboutWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 484),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About TexFast"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = AboutViewController()
        window.setContentSize(NSSize(width: 540, height: 484))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
