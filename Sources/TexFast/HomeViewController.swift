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
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {   // delete, forward delete
            onDelete?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {     // return, keypad enter
            onOpen?()
            return
        }
        super.keyDown(with: event)
    }
}

final class RecentFileCellView: NSTableCellView {
    private let fileIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)

        fileIcon.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right
        for label in [titleLabel, pathLabel, dateLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        for item in [fileIcon, titleLabel, pathLabel, dateLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        NSLayoutConstraint.activate([
            fileIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            fileIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            fileIcon.widthAnchor.constraint(equalToConstant: 30),
            fileIcon.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: fileIcon.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -12),
            pathLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            dateLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            dateLabel.widthAnchor.constraint(equalToConstant: 92)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(url: URL, modified: Date?) {
        let name = url.lastPathComponent
        titleLabel.stringValue = name == "main.tex" ? url.deletingLastPathComponent().lastPathComponent : name
        let fullPath = url.path
        let home = NSHomeDirectory()
        pathLabel.stringValue = fullPath.hasPrefix(home + "/") ? "~" + fullPath.dropFirst(home.count) : fullPath
        dateLabel.stringValue = modified.map {
            Self.relativeDate.localizedString(for: $0, relativeTo: Date())
        } ?? ""
        fileIcon.image = NSWorkspace.shared.icon(forFile: url.path)
        toolTip = fullPath
        setAccessibilityLabel("\(titleLabel.stringValue), \(pathLabel.stringValue)")
    }

    private static let relativeDate = RelativeDateTimeFormatter()
}

final class HomeViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    struct RecentFile {
        let url: URL
        let modified: Date?
    }

    private let tableView = RecentsTableView()
    private let scrollView = NSScrollView()
    private let openButton = NSButton(title: "Open LaTeX File…", target: nil, action: nil)
    private let recentHeader = NSTextField(labelWithString: "Recent files")
    private let emptyState = NSStackView()
    private let footer = NSTextField(labelWithString: "Double-click to open  ·  Delete to remove from Recents")
    private var files: [RecentFile] = []
    var onOpen: ((URL) -> Void)?
    var onChooseFile: (() -> Void)?

    override func loadView() {
        let root = NSView()
        let appIcon = NSImageView(image: NSApp.applicationIconImage)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "TexFast")
        title.font = .systemFont(ofSize: 30, weight: .bold)

        let subtitle = NSTextField(labelWithString: "Pick up where you left off")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        openButton.target = self
        openButton.action = #selector(chooseFile)
        openButton.bezelStyle = .rounded
        openButton.bezelColor = .controlAccentColor
        openButton.contentTintColor = .white
        openButton.controlSize = .large

        recentHeader.font = .systemFont(ofSize: 15, weight: .semibold)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recentFile"))
        column.width = 800
        column.minWidth = 300
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .plain
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.allowsMultipleSelection = true
        tableView.onDelete = { [weak self] in self?.removeSelected(nil) }
        tableView.onOpen = { [weak self] in self?.openSelected() }

        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "Open", action: #selector(openClicked), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Reveal in Finder", action: #selector(revealClicked), keyEquivalent: "")
        contextMenu.addItem(.separator())
        contextMenu.addItem(withTitle: "Remove from Recents", action: #selector(removeClicked), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Clear All Recents", action: #selector(clearAll(_:)), keyEquivalent: "")
        for item in contextMenu.items { item.target = self }
        tableView.menu = contextMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) ?? NSImage())
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 38, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        let emptyTitle = NSTextField(labelWithString: "No recent documents")
        emptyTitle.font = .systemFont(ofSize: 16, weight: .medium)
        let emptyDetail = NSTextField(labelWithString: "Open a .tex file to get started.")
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = .secondaryLabelColor
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 9
        for item in [emptyIcon, emptyTitle, emptyDetail] { emptyState.addArrangedSubview(item) }

        for item in [appIcon, title, subtitle, openButton, recentHeader, scrollView, emptyState, footer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            appIcon.topAnchor.constraint(equalTo: root.topAnchor, constant: 38),
            appIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            appIcon.widthAnchor.constraint(equalToConstant: 48),
            appIcon.heightAnchor.constraint(equalToConstant: 48),
            title.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: appIcon.topAnchor, constant: -2),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            openButton.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
            openButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            recentHeader.topAnchor.constraint(equalTo: appIcon.bottomAnchor, constant: 36),
            recentHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            scrollView.topAnchor.constraint(equalTo: recentHeader.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: recentHeader.leadingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])
        view = root
        reload()
    }

    func reload() {
        files = RecentFiles.all().map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return RecentFile(url: url, modified: attributes?[.modificationDate] as? Date)
        }
        recentHeader.stringValue = files.isEmpty ? "Recent files" : "Recent files (\(files.count))"
        emptyState.isHidden = !files.isEmpty
        scrollView.isHidden = files.isEmpty
        footer.isHidden = files.isEmpty
        tableView.reloadData()
    }

    func focusDefaultAction() {
        guard let window = view.window else { return }
        if files.isEmpty {
            window.makeFirstResponder(openButton)
        } else {
            if tableView.selectedRow < 0 {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            window.makeFirstResponder(tableView)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = files[row]
        let identifier = NSUserInterfaceItemIdentifier("recentFileCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? RecentFileCellView)
            ?? RecentFileCellView(frame: .zero)
        cell.identifier = identifier
        cell.configure(url: file.url, modified: file.modified)
        return cell
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
