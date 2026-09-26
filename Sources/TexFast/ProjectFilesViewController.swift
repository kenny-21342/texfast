import AppKit

private final class ProjectFileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    var children: [ProjectFileNode]?
    var directoryStamp: Date?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

/// A lazy project tree. Only the root and expanded folders are scanned, and a
/// small timer picks up files created by the built-in terminal or other apps.
final class ProjectFilesViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let projectURL: URL
    private let root: ProjectFileNode
    private var nodes: [URL: ProjectFileNode] = [:]
    private let outline = NSOutlineView()
    private var refreshTimer: Timer?

    var onOpen: ((URL) -> Void)?
    var onFilesAdded: (([URL]) -> Void)?
    var onError: ((String) -> Void)?

    init(projectURL: URL) {
        self.projectURL = projectURL.standardizedFileURL
        root = ProjectFileNode(url: projectURL.standardizedFileURL, isDirectory: true)
        super.init(nibName: nil, bundle: nil)
        nodes[root.url] = root
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("file"))
        column.width = 230
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        outline.indentationPerLevel = 13
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.registerForDraggedTypes([.fileURL, .png, .tiff])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
        outline.reloadData()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewWillDisappear() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        super.viewWillDisappear()
    }

    deinit { refreshTimer?.invalidate() }

    private func children(of node: ProjectFileNode) -> [ProjectFileNode] {
        if let children = node.children { return children }
        node.directoryStamp = modificationDate(of: node.url)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: node.url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let children = urls.filter { $0.lastPathComponent != ".texfast" }
            .map { url -> ProjectFileNode in
                let url = url.standardizedFileURL
                if let existing = nodes[url] { return existing }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let node = ProjectFileNode(url: url, isDirectory: isDirectory)
                nodes[url] = node
                return node
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        node.children = children
        return children
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item as? ProjectFileNode ?? root).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item as? ProjectFileNode ?? root)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ProjectFileNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ProjectFileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("projectFile")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let icon = NSImageView()
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingMiddle
            for child in [icon, label] {
                child.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(child)
            }
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()
        let ext = node.url.pathExtension.lowercased()
        let symbol = node.isDirectory ? "folder" :
            ["png", "jpg", "jpeg", "heic", "tiff", "gif", "svg"].contains(ext) ? "photo" :
            ext == "pdf" ? "doc.richtext" :
            ["tex", "bib", "sty", "cls"].contains(ext) ? "curlybraces" : "doc"
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.imageView?.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
        cell.textField?.stringValue = node.url.lastPathComponent
        cell.toolTip = node.url.path
        return cell
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? ProjectFileNode,
              !node.isDirectory else { return }
        onOpen?(node.url)
    }

    @objc private func rowDoubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? ProjectFileNode,
              node.isDirectory else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) }
        else { outline.expandItem(node) }
    }

    func refresh(force: Bool = false) {
        guard isViewLoaded else { return }
        let selected = (outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? ProjectFileNode : nil)?.url
        let expanded = nodes.values.filter { $0.isDirectory && outline.isItemExpanded($0) }
        var changed = force
        for node in [root] + expanded {
            if force || modificationDate(of: node.url) != node.directoryStamp {
                node.children = nil
                changed = true
            }
        }
        guard changed else { return }
        outline.reloadData()
        expanded.forEach { outline.expandItem($0) }
        if let selected { select(selected) }
    }

    func select(_ url: URL) {
        guard isViewLoaded else { return }
        let target = url.standardizedFileURL
        var ancestors: [URL] = []
        var parent = target.deletingLastPathComponent()
        while parent != projectURL && parent.path.hasPrefix(projectURL.path + "/") {
            ancestors.append(parent)
            parent = parent.deletingLastPathComponent()
        }
        for folder in ancestors.reversed() {
            if let node = nodes[folder] { outline.expandItem(node) }
        }
        if let node = nodes[target] {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
    }

    private func destination(for proposedItem: Any?) -> URL {
        guard let node = proposedItem as? ProjectFileNode else { return projectURL }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        let types = pasteboard.types ?? []
        guard types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff) else { return [] }
        outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        let pasteboard = info.draggingPasteboard
        let sourceURLs = (pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageData: Data? = sourceURLs.isEmpty
            ? pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            } : nil
        guard !sourceURLs.isEmpty || imageData != nil else { return false }
        let folder = destination(for: item)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var added: [URL] = []
            var failures: [String] = []
            for source in sourceURLs {
                let source = source.standardizedFileURL
                let canonical = source.resolvingSymlinksInPath()
                let destination = folder.resolvingSymlinksInPath()
                if destination == canonical || destination.path.hasPrefix(canonical.path + "/") {
                    failures.append("Cannot copy a folder into itself: \(source.lastPathComponent)")
                    continue
                }
                let target = Self.uniqueDestination(for: source.lastPathComponent, in: folder)
                do { try FileManager.default.copyItem(at: source, to: target); added.append(target) }
                catch { failures.append("\(source.lastPathComponent): \(error.localizedDescription)") }
            }
            if let imageData {
                let target = Self.uniqueDestination(for: "Screenshot.png", in: folder)
                do { try imageData.write(to: target, options: .atomic); added.append(target) }
                catch { failures.append("Screenshot: \(error.localizedDescription)") }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                refresh(force: true)
                if let first = added.first { select(first) }
                if !added.isEmpty { onFilesAdded?(added) }
                if !failures.isEmpty { onError?(failures.joined(separator: "\n")) }
            }
        }
        return true
    }

    private static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let nameURL = URL(fileURLWithPath: name)
        let stem = nameURL.deletingPathExtension().lastPathComponent
        let ext = nameURL.pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = "\(stem) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = folder.appendingPathComponent(next)
            number += 1
        }
        return candidate
    }
}
