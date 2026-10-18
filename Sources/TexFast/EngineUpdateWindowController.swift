import AppKit
import TexFastCore

final class EngineUpdateWindowController: NSWindowController {
    private let store: EngineStore
    private let bundled: EnginePackage
    private let running: EnginePackage
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let primary = NSButton(title: "Check for Updates", target: nil, action: nil)
    private let rollback = NSButton(title: "Use Bundled Engine…", target: nil, action: nil)
    private var release: EngineRelease?
    private var busy = false

    init(bundled: EnginePackage, running: EnginePackage, store: EngineStore = EngineStore()) {
        self.bundled = bundled; self.running = running; self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 245),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Realtime Engine Updates"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        let root = window.contentView!
        let heading = NSTextField(labelWithString: "Realtime typesetting engine")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        summary.font = .systemFont(ofSize: 12)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        progress.style = .spinning; progress.controlSize = .small
        primary.target = self; primary.action = #selector(performPrimary)
        rollback.target = self; rollback.action = #selector(useBundled)
        let notes = NSButton(title: "Release Notes", target: self, action: #selector(showReleaseNotes))
        for view in [heading, summary, detail, progress, primary, rollback, notes] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            summary.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            summary.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            detail.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            detail.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 14),
            progress.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            progress.bottomAnchor.constraint(equalTo: primary.topAnchor, constant: -12),
            progress.widthAnchor.constraint(equalToConstant: 16), progress.heightAnchor.constraint(equalToConstant: 16),
            primary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            primary.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            rollback.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            rollback.centerYAnchor.constraint(equalTo: primary.centerYAnchor),
            notes.trailingAnchor.constraint(equalTo: primary.trailingAnchor),
            notes.bottomAnchor.constraint(equalTo: primary.topAnchor, constant: -12)
        ])
        refreshSummary()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showAndCheck() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        if !busy { check() }
    }
    private func refreshSummary() {
        let next = store.selected(compatibleWith: bundled.version) ?? bundled
        summary.stringValue = "Running: \(running.version)  ·  Bundled: \(bundled.version)" +
            (next.binary != running.binary ? "\nAfter restart: \(next.version)" : "")
        rollback.isEnabled = store.hasSelection && !busy
    }
    private func setBusy(_ value: Bool, _ message: String) {
        busy = value; primary.isEnabled = !value
        detail.stringValue = message
        progress.isHidden = !value
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        refreshSummary()
    }
    @objc private func performPrimary() {
        if let release { install(release) } else { check() }
    }
    private func check() {
        release = nil; primary.title = "Check Again"
        setBusy(true, "Checking GitHub for a stable engine release…")
        Task { @MainActor in
            do {
                let latest = try await EngineUpdates.latest()
                _ = try latest.asset(bundledVersion: bundled.version)
                let next = store.selected(compatibleWith: bundled.version) ?? bundled
                if let version = EngineVersion(latest.tag_name), let current = EngineVersion(next.version), version > current {
                    release = latest; primary.title = "Install \(latest.tag_name)"
                    setBusy(false, "Engine \(latest.tag_name) is available. Updates take effect after you quit and reopen TexFast Realtime.")
                } else {
                    setBusy(false, "You have the latest compatible engine. Updates are checked only when you choose this option.")
                }
            } catch { setBusy(false, error.localizedDescription) }
        }
    }
    private func install(_ release: EngineRelease) {
        setBusy(true, "Downloading and verifying engine \(release.tag_name)…")
        Task { @MainActor in
            do {
                let asset = try release.asset(bundledVersion: bundled.version)
                let archive = try await EngineUpdates.download(asset)
                defer { try? FileManager.default.removeItem(at: archive) }
                let store = self.store, version = bundled.version
                _ = try await Task.detached(priority: .userInitiated) {
                    try store.install(archive: archive, release: release, bundledVersion: version)
                }.value
                self.release = nil; primary.title = "Check Again"
                setBusy(false, "Engine \(release.tag_name) is ready. Quit and reopen TexFast Realtime to use it. Your open documents keep their current engine until then.")
            } catch { setBusy(false, error.localizedDescription) }
        }
    }
    @objc private func useBundled() {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = "Use the bundled engine \(bundled.version)?"
        alert.informativeText = "This takes effect after you quit and reopen TexFast Realtime. Your current editing session will continue."
        alert.addButton(withTitle: "Use Bundled Engine"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.useBundled()
            release = nil; primary.title = "Check for Updates"
            setBusy(false, "The bundled engine will be used after restart.")
        } catch { setBusy(false, error.localizedDescription) }
    }
    @objc private func showReleaseNotes() {
        let url = release.map { "https://github.com/kenny-21342/realtime-tex/releases/tag/\($0.tag_name)" }
            ?? "https://github.com/kenny-21342/realtime-tex/releases"
        NSWorkspace.shared.open(URL(string: url)!)
    }
}
