import AppKit

/// Recently-opened files, kept in UserDefaults.
///
/// `NSDocumentController.recentDocumentURLs` comes back empty here: TexFast is
/// not built on the NSDocument architecture, so the shared controller records
/// nothing we can read back. A small list of our own is both reliable and
/// easier to curate (drop files that have since been deleted).
enum RecentFiles {
    private static let key = "TexFastRecentDocuments"
    private static let limit = 12

    static func all() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Both sides of every comparison go through this. `standardizedFileURL`
    /// alone is not enough: it rewrites `/private/tmp` to `/tmp`, so a stored
    /// path and the URL built from it can disagree and a removal silently
    /// matches nothing.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func remove(_ urls: [URL]) {
        let dropping = Set(urls.map { canonical($0.path) })
        let paths = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { !dropping.contains(canonical($0)) }
        UserDefaults.standard.set(paths, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        let canon = canonical(path)
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { canonical($0) == canon }
        paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }
}

/// Table that reports the Delete key, so a recent entry can be forgotten the
/// same way a file is removed from any other macOS list.
final class RecentsTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {   // delete, forward delete
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

final class HomeViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    struct RecentFile {
        let url: URL
        let modified: Date?
    }

    private let tableView = RecentsTableView()
    private let emptyLabel = NSTextField(labelWithString: "No recent files")
    private var files: [RecentFile] = []
    var onOpen: ((URL) -> Void)?
    var onChooseFile: (() -> Void)?

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "TexFast")
        title.font = .systemFont(ofSize: 34, weight: .bold)

        let subtitle = NSTextField(labelWithString: "Recently opened LaTeX documents")
        subtitle.textColor = .secondaryLabelColor

        let openButton = NSButton(title: "Open LaTeX File...", target: self, action: #selector(chooseFile))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 260
        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = "Location"
        pathColumn.width = 480
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(pathColumn)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.allowsMultipleSelection = true
        tableView.onDelete = { [weak self] in self?.removeSelected(nil) }

        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "Open", action: #selector(openClicked), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Reveal in Finder", action: #selector(revealClicked), keyEquivalent: "")
        contextMenu.addItem(.separator())
        contextMenu.addItem(withTitle: "Remove from Recents", action: #selector(removeClicked), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Clear All Recents", action: #selector(clearAll(_:)), keyEquivalent: "")
        for item in contextMenu.items { item.target = self }
        tableView.menu = contextMenu

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor

        for item in [title, subtitle, openButton, scroll, emptyLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 48),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            openButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            openButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48),
            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 28),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 48),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -48),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        view = root
        reload()
    }

    func reload() {
        files = RecentFiles.all().map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return RecentFile(url: url, modified: attributes?[.modificationDate] as? Date)
        }
        emptyLabel.isHidden = !files.isEmpty
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = files[row]
        let field = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "name"
            ? file.url.lastPathComponent
            : file.url.deletingLastPathComponent().path)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = file.url.path
        return field
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(clearAll(_:)):
            return !files.isEmpty
        case #selector(removeClicked), #selector(removeSelected(_:)),
             #selector(openClicked), #selector(revealClicked):
            return !targetRows().isEmpty
        default:
            return true
        }
    }

    @objc private func chooseFile() { onChooseFile?() }

    /// Rows a context-menu action applies to: the row under the cursor when it
    /// is outside the selection, otherwise the whole selection.
    private func targetRows() -> IndexSet {
        let clicked = tableView.clickedRow
        if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) {
            return IndexSet(integer: clicked)
        }
        if tableView.selectedRowIndexes.isEmpty, clicked >= 0 {
            return IndexSet(integer: clicked)
        }
        return tableView.selectedRowIndexes
    }

    @objc private func removeClicked() { remove(rows: targetRows()) }

    /// Internal, not private: the File menu targets it through the responder chain.
    @objc func removeSelected(_ sender: Any?) { remove(rows: tableView.selectedRowIndexes) }

    private func remove(rows: IndexSet) {
        let urls = rows.compactMap { $0 < files.count ? files[$0].url : nil }
        guard !urls.isEmpty else { return }
        let firstRemoved = rows.min() ?? 0
        RecentFiles.remove(urls)
        reload()
        // Keep a sensible selection so repeated deletes need no re-aiming.
        if !files.isEmpty {
            let next = min(firstRemoved, files.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
    }

    @objc func clearAll(_ sender: Any?) {
        RecentFiles.clear()
        reload()
    }

    @objc private func openClicked() {
        guard let row = targetRows().first, row < files.count else { return }
        onOpen?(files[row].url)
    }

    @objc private func revealClicked() {
        let urls = targetRows().compactMap { $0 < files.count ? files[$0].url : nil }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func openSelected() {
        guard tableView.selectedRow >= 0 else { return }
        onOpen?(files[tableView.selectedRow].url)
    }
}

final class HomeWindowController: NSWindowController {
    let home = HomeViewController()

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "TexFast"
        window.setFrameAutosaveName("TexFastHome")
        self.init(window: window)
        window.contentViewController = home
        // Assigning contentViewController resizes the window to the view's
        // fitting size, which for a constraint-only layout collapses to a
        // sliver. Restore the intended size afterwards and pin a floor.
        window.setContentSize(NSSize(width: 900, height: 580))
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
    }
}
