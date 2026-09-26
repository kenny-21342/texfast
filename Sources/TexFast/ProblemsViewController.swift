import AppKit

struct Problem {
    let url: URL?
    let line: Int?                 // 1-based
    let severity: Int             // 1 error, 2 warning, 3 information
    let message: String
    let origin: String

    var location: String {
        guard let url else { return origin }
        return url.lastPathComponent + (line.map { ":\($0)" } ?? "")
    }
}

/// Parses the file:line:message format produced by XeLaTeX's
/// -file-line-error option. The main file in the output is the shadow copy;
/// included files are resolved against the project directory.
enum BuildProblems {
    private static let fileLine = try! NSRegularExpression(
        pattern: #"^(.+?\.(?:tex|sty|cls|bib)):(\d+):\s*(.+)$"#)
    private static let warningLine = try! NSRegularExpression(
        pattern: #"(?:on input line|at line)\s+(\d+)"#)

    static func parse(_ output: String, root: URL, shadow: URL, project: URL) -> [Problem] {
        var result: [Problem] = []
        var seen = Set<String>()
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            if let hit = fileLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: hit.range(at: 1))
                let number = Int(ns.substring(with: hit.range(at: 2)))
                let message = ns.substring(with: hit.range(at: 3))
                let url = sourceURL(path, root: root, shadow: shadow, project: project)
                let severity = message.contains("Warning:") ? 2 : 1
                append(Problem(url: url, line: number, severity: severity,
                               message: message, origin: "Build"), to: &result, seen: &seen)
            } else if line.hasPrefix("LaTeX Warning:") ||
                        (line.hasPrefix("Package ") && line.contains(" Warning:")) {
                let hit = warningLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
                let number = hit.flatMap { Int(ns.substring(with: $0.range(at: 1))) }
                append(Problem(url: root, line: number, severity: 2,
                               message: line, origin: "Build"), to: &result, seen: &seen)
            }
            if result.count >= 200 { break }
        }
        return result
    }

    private static func sourceURL(_ path: String, root: URL, shadow: URL, project: URL) -> URL {
        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).standardizedFileURL
            : URL(fileURLWithPath: path, relativeTo: shadow.deletingLastPathComponent()).standardizedFileURL
        if candidate == shadow { return root }
        let resolved = candidate.resolvingSymlinksInPath()
        if resolved == shadow { return root }
        if FileManager.default.fileExists(atPath: resolved.path) { return resolved }
        let inProject = project.appendingPathComponent(path).standardizedFileURL
        return FileManager.default.fileExists(atPath: inProject.path) ? inProject : root
    }

    private static func append(_ problem: Problem, to result: inout [Problem], seen: inout Set<String>) {
        let key = "\(problem.severity)|\(problem.url?.path ?? "")|\(problem.line ?? 0)|\(problem.message)"
        if seen.insert(key).inserted { result.append(problem) }
    }
}

final class ProblemsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No problems")
    private var problems: [Problem] = []
    var onSelect: ((Problem) -> Void)?

    override func loadView() {
        let root = NSView()
        let scroll = NSScrollView()
        let message = NSTableColumn(identifier: .init("message"))
        message.width = 420
        let location = NSTableColumn(identifier: .init("location"))
        location.width = 130
        table.addTableColumn(message)
        table.addTableColumn(location)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.usesAlternatingRowBackgroundColors = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        for child in [scroll, emptyLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
        view = root
    }

    func update(_ problems: [Problem]) {
        self.problems = problems
        table.reloadData()
        emptyLabel.isHidden = !problems.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { problems.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let item = problems[row]
        let identifier = column?.identifier ?? .init("message")
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? {
            let value = NSTextField(labelWithString: "")
            value.identifier = identifier
            value.lineBreakMode = .byTruncatingTail
            return value
        }()
        field.font = .systemFont(ofSize: 11)
        if identifier.rawValue == "message" {
            field.stringValue = "●  " + item.message.replacingOccurrences(of: "\n", with: " ")
            field.textColor = item.severity == 1 ? .systemRed :
                item.severity == 2 ? .systemOrange : .secondaryLabelColor
            field.toolTip = item.message
        } else {
            field.stringValue = item.location
            field.textColor = .secondaryLabelColor
            field.toolTip = item.url?.path ?? item.origin
        }
        return field
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < problems.count else { return }
        onSelect?(problems[row])
    }
}
