import AppKit

/// Section list built from texlab's document symbols.
final class OutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var items: [OutlineItem] = []
    var onSelect: ((Int) -> Void)?
    var onCountChanged: ((Int) -> Void)?

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 200
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList
        table.target = self
        table.action = #selector(rowClicked)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    func update(_ items: [OutlineItem]) {
        self.items = items
        table.reloadData()
        onCountChanged?(items.count)
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < items.count else { return }
        onSelect?(items[row].line + 1)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("outlineCell")
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        let item = items[row]
        field.stringValue = String(repeating: "   ", count: min(item.depth, 4)) + item.name
        field.font = .systemFont(ofSize: item.depth == 0 ? 12 : 11,
                                 weight: item.depth == 0 ? .semibold : .regular)
        field.textColor = item.depth == 0 ? .labelColor : .secondaryLabelColor
        return field
    }
}
