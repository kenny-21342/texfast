import AppKit

/// Borderless popup listing texlab's suggestions. It is deliberately
/// non-activating: the text view keeps first responder status so typing keeps
/// filtering rather than being swallowed by the panel.
final class CompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private(set) var items: [CompletionItem] = []
    var onCommit: ((CompletionItem) -> Void)?

    var isVisible: Bool { panel.isVisible }
    var selected: CompletionItem? {
        let row = table.selectedRow
        return (row >= 0 && row < items.count) ? items[row] : nil
    }

    override init() {
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true

        let labelColumn = NSTableColumn(identifier: .init("label"))
        labelColumn.width = 180
        let detailColumn = NSTableColumn(identifier: .init("detail"))
        detailColumn.width = 180
        table.addTableColumn(labelColumn)
        table.addTableColumn(detailColumn)
        table.headerView = nil
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.target = self
        table.doubleAction = #selector(commitSelection)
        table.style = .plain

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4)
        ])
        panel.contentView = container
    }

    func show(_ items: [CompletionItem], at screenPoint: NSPoint, parent: NSWindow) {
        guard !items.isEmpty else { hide(); return }
        self.items = items
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)

        let height = min(CGFloat(items.count) * table.rowHeight + 8, 220)
        var frame = NSRect(x: screenPoint.x, y: screenPoint.y - height, width: 380, height: height)
        if let screen = parent.screen {
            // Flip above the caret when there is no room below.
            if frame.minY < screen.visibleFrame.minY { frame.origin.y = screenPoint.y + 18 }
            frame.origin.x = min(frame.origin.x, screen.visibleFrame.maxX - frame.width - 8)
        }
        panel.setFrame(frame, display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc func commitSelection() {
        guard let item = selected else { return }
        onCommit?(item)
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let isLabel = tableColumn?.identifier.rawValue == "label"
        let id = NSUserInterfaceItemIdentifier(isLabel ? "labelCell" : "detailCell")
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            f.font = isLabel ? .monospacedSystemFont(ofSize: 12, weight: .regular)
                             : .systemFont(ofSize: 11)
            return f
        }()
        let item = items[row]
        field.stringValue = isLabel ? item.label : (item.detail ?? "")
        field.textColor = isLabel ? .labelColor : .secondaryLabelColor
        return field
    }
}
