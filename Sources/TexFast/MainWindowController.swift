import AppKit
import TexFastCore

private let autoCompileDefaultsKey = "TexFastAutoCompile"

/// Small native heading for each pane. The content controller keeps its own
/// scroll view, so this adds no work to editor layout or PDF rendering.
private final class PaneController: NSViewController {
    private let contentController: NSViewController
    private let titleText: String
    private let symbolName: String
    private let detail = NSTextField(labelWithString: "")

    init(_ title: String, symbol: String, content: NSViewController) {
        titleText = title
        symbolName = symbol
        contentController = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        let header = NSVisualEffectView()
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active

        let icon = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let divider = NSBox()
        divider.boxType = .separator

        addChild(contentController)
        let content = contentController.view
        for item in [header, content] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        for item in [icon, title, detail, divider] {
            item.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 11),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -8),
            detail.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -11),
            detail.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])
        view = root
    }

    func setDetail(_ text: String, color: NSColor = .tertiaryLabelColor, toolTip: String? = nil) {
        detail.stringValue = text
        detail.textColor = color
        detail.toolTip = toolTip
    }
}

final class MainWindowController: NSWindowController, NSMenuItemValidation {

    var documentURL: URL { fileURL }

    private let editor = EditorViewController()
    private let preview = PDFPaneController()
    private let outline = OutlineViewController()
    private let problems = ProblemsViewController()
    private var files: ProjectFilesViewController!
    private lazy var filesPane = PaneController("FILES", symbol: "folder", content: files)
    private lazy var outlinePane = PaneController("CONTENTS", symbol: "list.bullet", content: outline)
    private lazy var editorPane = PaneController("SOURCE", symbol: "chevron.left.forwardslash.chevron.right", content: editor)
    private lazy var previewPane = PaneController("PREVIEW", symbol: "doc.richtext", content: preview)
    private lazy var problemsPane = PaneController("PROBLEMS", symbol: "exclamationmark.circle", content: problems)
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let modeLabel = NSTextField(labelWithString: "")
    private let problemsButton = NSButton()
    private let terminalButton = NSButton()
    private var splitController: NSSplitViewController!
    private var sourceController: NSSplitViewController!
    private var problemsItem: NSSplitViewItem!
    private var workspaceController: NSSplitViewController!
    private var terminalController: TerminalPaneController?
    private var terminalItem: NSSplitViewItem?

    private var lsp: LSPClient?
    private var builder: BuildController!
    private var fileURL: URL!
    private var symbolWork: DispatchWorkItem?
    private var sourceWatcher: FileWatcher?
    private var pdfWatcher: FileWatcher?
    private var projectWatcher: ProjectChangeWatcher?
    private var diagnosticsByFile: [URL: [Diagnostic]] = [:]
    private var compileProblems: [Problem] = []
    private var problemsDismissed = false
    private var previewPage = 0
    private var previewPageCount = 0
    private enum PreviewState { case previous, stale, building, current, issues, failed, external }
    private var previewState: PreviewState = .previous

    convenience init(fileURL: URL) {
        let fileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = fileURL.lastPathComponent
        window.representedURL = fileURL
        window.setFrameAutosaveName("TexFastMain")
        self.init(window: window)
        self.fileURL = fileURL
        assemble()
        open()
    }

    // MARK: - layout

    private func assemble() {
        files = ProjectFilesViewController(projectURL: fileURL.deletingLastPathComponent())
        let filesItem = NSSplitViewItem(viewController: filesPane)
        filesItem.minimumThickness = 130
        filesItem.preferredThicknessFraction = 0.52
        let contentsItem = NSSplitViewItem(viewController: outlinePane)
        contentsItem.minimumThickness = 110
        let sidebarController = NSSplitViewController()
        sidebarController.splitView.isVertical = false
        sidebarController.splitView.dividerStyle = .thin
        sidebarController.addSplitViewItem(filesItem)
        sidebarController.addSplitViewItem(contentsItem)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 185
        sidebarItem.maximumThickness = 330
        sidebarItem.canCollapse = true

        sourceController = NSSplitViewController()
        sourceController.splitView.isVertical = false
        sourceController.splitView.dividerStyle = .thin
        let editorInnerItem = NSSplitViewItem(viewController: editorPane)
        editorInnerItem.minimumThickness = 280
        problemsItem = NSSplitViewItem(viewController: problemsPane)
        problemsItem.minimumThickness = 110
        problemsItem.maximumThickness = 330
        problemsItem.preferredThicknessFraction = 0.25
        problemsItem.canCollapse = true
        sourceController.addSplitViewItem(editorInnerItem)
        sourceController.addSplitViewItem(problemsItem)
        problemsItem.isCollapsed = true
        let editorItem = NSSplitViewItem(viewController: sourceController)
        editorItem.minimumThickness = 320
        let previewItem = NSSplitViewItem(viewController: previewPane)
        previewItem.minimumThickness = 320

        splitController = NSSplitViewController()
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(editorItem)
        splitController.addSplitViewItem(previewItem)
        splitController.splitView.dividerStyle = .thin

        workspaceController = NSSplitViewController()
        workspaceController.splitView.isVertical = false
        workspaceController.splitView.dividerStyle = .thin
        let documentItem = NSSplitViewItem(viewController: splitController)
        documentItem.minimumThickness = 320
        workspaceController.addSplitViewItem(documentItem)

        let root = NSView()
        let split = workspaceController.view
        let statusBar = NSVisualEffectView()
        statusBar.material = .headerView
        statusBar.blendingMode = .withinWindow
        statusBar.state = .active
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        let statusDivider = NSBox()
        statusDivider.boxType = .separator
        statusDivider.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        modeLabel.textColor = .tertiaryLabelColor
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        problemsButton.title = "Problems"
        problemsButton.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
        problemsButton.imagePosition = .imageLeading
        problemsButton.font = .systemFont(ofSize: 10, weight: .medium)
        problemsButton.contentTintColor = .secondaryLabelColor
        problemsButton.isBordered = false
        problemsButton.target = self
        problemsButton.action = #selector(toggleProblems(_:))
        problemsButton.toolTip = "Toggle Problems (⌘2)"
        problemsButton.translatesAutoresizingMaskIntoConstraints = false
        terminalButton.title = "Terminal"
        terminalButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        terminalButton.imagePosition = .imageLeading
        terminalButton.font = .systemFont(ofSize: 10, weight: .medium)
        terminalButton.contentTintColor = .secondaryLabelColor
        terminalButton.isBordered = false
        terminalButton.state = .off
        terminalButton.target = self
        terminalButton.action = #selector(toggleTerminal(_:))
        terminalButton.toolTip = "Toggle Terminal (⌘1)"
        terminalButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(split)
        root.addSubview(statusBar)
        for item in [statusDivider, spinner, status, problemsButton, terminalButton, modeLabel] {
            statusBar.addSubview(item)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 27),
            statusDivider.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            statusDivider.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            statusDivider.topAnchor.constraint(equalTo: statusBar.topAnchor),
            spinner.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 11),
            spinner.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
            status.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            status.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: problemsButton.leadingAnchor, constant: -12),
            problemsButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            problemsButton.trailingAnchor.constraint(equalTo: terminalButton.leadingAnchor, constant: -10),
            terminalButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            terminalButton.trailingAnchor.constraint(equalTo: modeLabel.leadingAnchor, constant: -16),
            modeLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            modeLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12)
        ])
        window?.contentView = root
        // NSSplitViewController restores its initial layout when attached to a
        // window, which can undo an earlier isCollapsed assignment.
        DispatchQueue.main.async { [weak self] in
            self?.problemsItem.isCollapsed = true
            self?.problemsButton.state = .off
        }
        window?.makeFirstResponder(editor.textView)
    }

    // MARK: - wiring

    private func open() {
        let projectDir = fileURL.deletingLastPathComponent()
        let driver = Driver(texFile: fileURL,
                            projectDir: projectDir,
                            cacheDir: projectDir.appendingPathComponent(".texfast"),
                            draft: true,
                            jobs: ProcessInfo.processInfo.activeProcessorCount)
        builder = BuildController(driver: driver)

        lsp = LSPClient(rootURI: projectDir)
        lsp?.start()
        lsp?.onDiagnostics = { [weak self] url, diagnostics in
            guard let self else { return }
            diagnosticsByFile[url] = diagnostics
            if url == editor.fileURL { editor.apply(diagnostics) }
            refreshProblems()
        }
        editor.lsp = lsp

        // Auto-compile is on unless the user has turned it off before.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: autoCompileDefaultsKey) == nil {
            defaults.set(true, forKey: autoCompileDefaultsKey)
        }
        editor.autoCompile = defaults.bool(forKey: autoCompileDefaultsKey)
        updateModeLabel()
        editorPane.setDetail(fileURL.lastPathComponent)
        filesPane.setDetail(projectDir.lastPathComponent)
        files.onOpen = { [weak self] url in self?.openProjectFile(url) }
        files.onFilesAdded = { [weak self] added in
            guard let self else { return }
            status.stringValue = added.count == 1
                ? "Added \(added[0].lastPathComponent) to the project"
                : "Added \(added.count) files to the project"
            builder.sourceDidChange()
            setPreviewState(.stale)
            added.forEach { self.projectWatcher?.acknowledgeOwnWrite($0) }
            if editor.autoCompile { builder.build() }
        }
        files.onError = { [weak self] message in
            let alert = NSAlert()
            alert.messageText = "Could not add every file"
            alert.informativeText = message
            alert.runModal()
            self?.files.refresh()
        }
        problems.onSelect = { [weak self] problem in self?.openProblem(problem) }
        refreshProblems()
        outline.onCountChanged = { [weak self] count in
            self?.outlinePane.setDetail(count == 0 ? "" : "\(count)")
        }
        preview.onPageChanged = { [weak self] page, total in
            self?.previewPage = page
            self?.previewPageCount = total
            self?.updatePreviewDetail()
        }

        editor.onSave = { [weak self] in
            self?.sourceWatcher?.acknowledgeOwnWrite()
            if let url = self?.editor.fileURL { self?.projectWatcher?.acknowledgeOwnWrite(url) }
            self?.builder.build()
        }
        editor.onAutoSaveBlocked = { [weak self] in
            self?.status.stringValue = "\(self?.fileURL.lastPathComponent ?? "The file") changed on disk — auto-compile paused, ⌘S to overwrite"
        }
        editor.onTextChanged = { [weak self] _ in
            guard let self else { return }
            builder.sourceDidChange()
            setPreviewState(.stale)
            if !compileProblems.isEmpty { compileProblems = []; refreshProblems() }
            if !editor.autoCompile { scheduleSymbolRefresh() }
        }
        editor.onForwardSync = { [weak self] line, column in self?.forwardSync(line: line, column: column) }

        preview.onReverseSync = { [weak self] location in
            guard let self else { return }
            let source = location.url == builder.shadowURL ? fileURL! : location.url.resolvingSymlinksInPath()
            guard openSource(source) else { return }
            editor.jump(toLine: location.line)
            window?.makeFirstResponder(editor.textView)
        }
        outline.onSelect = { [weak self] line in
            guard let self else { return }
            editor.jump(toLine: line)
            forwardSync(line: line, column: 1)
        }

        builder.onState = { [weak self] state, message in
            guard let self else { return }
            status.stringValue = message
            if state == .idle { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
            if state == .building && !editor.hasUnsavedChanges { setPreviewState(.building) }
        }
        builder.onFinished = { [weak self] result in
            guard let self else { return }
            pdfWatcher?.acknowledgeOwnWrite()
            guard let result else { return }
            updateCompileProblems(from: result)
            if result.pdf != nil { preview.reload() }
            if result.error != nil { setPreviewState(.failed) }
            else if result.texHadErrors { setPreviewState(.issues) }
            else if editor.hasUnsavedChanges { setPreviewState(.stale) }
            else { setPreviewState(.current) }
            if result.error != nil || result.texHadErrors { revealProblemsAfterFailure() }
            scheduleSymbolRefresh()
        }

        try? editor.load(fileURL)
        files.select(fileURL)
        preview.load(builder.pdfURL)
        setPreviewState(.previous)
        startWatching()
        scheduleSymbolRefresh()

        builder.build()

        if lsp?.isRunning != true {
            status.stringValue = "texlab not found — completion is off. Install with: brew install texlab"
        }
    }

    /// Keep both panes in step with whatever else is touching the project — a
    /// coding agent rewriting the source, or a `fastex` build run from a terminal.
    private func startWatching() {
        sourceWatcher = FileWatcher(url: fileURL) { [weak self] in self?.sourceChangedOnDisk() }
        sourceWatcher?.start()

        // A little more settle time: the PDF is written progressively and is
        // unreadable until LuaLaTeX finishes writing it.
        pdfWatcher = FileWatcher(url: builder.pdfURL, interval: 0.6, settle: 0.7) { [weak self] in
            guard let self else { return }
            // LuaLaTeX replaces its PDF during our own build. Only an external
            // writer should make the visible preview say EXTERNAL.
            guard !builder.isBusy else { return }
            preview.reload()
            setPreviewState(editor.hasUnsavedChanges ? .stale : .external)
            status.stringValue = "Preview updated \(Self.clock.string(from: Date()))"
        }
        pdfWatcher?.start()

        let finalPDF = fileURL.deletingPathExtension().appendingPathExtension("pdf")
        projectWatcher = ProjectChangeWatcher(projectURL: fileURL.deletingLastPathComponent(),
                                              rootPDF: finalPDF) { [weak self] changed in
            guard let self else { return }
            let otherFiles = changed.filter { $0 != self.editor.fileURL }
            guard !otherFiles.isEmpty else { return }
            files.refresh(force: true)
            builder.sourceDidChange()
            setPreviewState(.stale)
            status.stringValue = otherFiles.count == 1
                ? "\(otherFiles[0].lastPathComponent) changed — preview is stale"
                : "Project files changed — preview is stale"
            if editor.autoCompile { builder.build() }
        }
        projectWatcher?.start()
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func setPreviewState(_ state: PreviewState) {
        previewState = state
        updatePreviewDetail()
    }

    private func updatePreviewDetail() {
        let page = previewPageCount > 0 ? "\(previewPage) / \(previewPageCount) · " : ""
        let label: String
        let color: NSColor
        let tip: String
        switch previewState {
        case .previous:
            (label, color, tip) = ("PREVIOUS", .tertiaryLabelColor, "A saved preview; a new build has not finished yet")
        case .stale:
            (label, color, tip) = ("STALE", .systemOrange, "The source or project files changed after this PDF")
        case .building:
            (label, color, tip) = ("UPDATING", .controlAccentColor, "A preview build is running")
        case .current:
            (label, color, tip) = ("CURRENT", .systemGreen, "The latest preview build completed without TeX errors")
        case .issues:
            (label, color, tip) = ("ISSUES", .systemOrange, "LuaLaTeX produced a PDF with errors; it may be incomplete")
        case .failed:
            (label, color, tip) = ("FAILED", .systemRed, "The last build failed; the visible PDF is older")
        case .external:
            (label, color, tip) = ("EXTERNAL", .secondaryLabelColor, "The PDF changed outside TexFast; source match is unverified")
        }
        previewPane.setDetail(page + label, color: color, toolTip: tip)
    }

    private func refreshProblems() {
        let languageProblems = diagnosticsByFile.flatMap { url, diagnostics in
            diagnostics.map { Problem(url: url, line: $0.line + 1, severity: $0.severity,
                                      message: $0.message, origin: "texlab") }
        }
        let all = (compileProblems + languageProblems).sorted {
            if $0.severity != $1.severity { return $0.severity < $1.severity }
            if $0.location != $1.location { return $0.location < $1.location }
            return $0.message < $1.message
        }
        problems.update(all)
        let errors = all.filter { $0.severity == 1 }.count
        let warnings = all.filter { $0.severity == 2 }.count
        problemsPane.setDetail("\(errors) errors · \(warnings) warnings")
        problemsButton.title = all.isEmpty ? "Problems" : "\(all.count) Problems"
        problemsButton.contentTintColor = errors > 0 ? .systemRed :
            warnings > 0 ? .systemOrange : .secondaryLabelColor
    }

    private func updateCompileProblems(from result: BuildReport) {
        compileProblems = BuildProblems.parse(result.texOutput, root: fileURL,
                                              shadow: builder.shadowURL,
                                              project: fileURL.deletingLastPathComponent())
        if let error = result.error, !compileProblems.contains(where: { $0.severity == 1 }) {
            compileProblems.insert(Problem(url: nil, line: nil, severity: 1,
                                           message: error, origin: "Build"), at: 0)
        } else if result.texHadErrors && !compileProblems.contains(where: { $0.severity == 1 }) {
            compileProblems.insert(Problem(url: nil, line: nil, severity: 1,
                                           message: "LuaLaTeX reported errors; inspect the build log.",
                                           origin: "Build"), at: 0)
        }
        refreshProblems()
    }

    private func revealProblemsAfterFailure() {
        guard !problemsDismissed else { return }
        problemsItem.isCollapsed = false
        problemsButton.state = .on
    }

    private func openProblem(_ problem: Problem) {
        guard let url = problem.url else {
            if FileManager.default.fileExists(atPath: builder.buildLogURL.path) {
                NSWorkspace.shared.open(builder.buildLogURL)
            }
            return
        }
        guard openSource(url) else { return }
        if let line = problem.line { editor.jump(toLine: line) }
        window?.makeFirstResponder(editor.textView)
    }

    private func openProjectFile(_ url: URL) {
        let sourceExtensions: Set<String> = ["tex", "bib", "sty", "cls"]
        if sourceExtensions.contains(url.pathExtension.lowercased()) {
            _ = openSource(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    private func openSource(_ url: URL) -> Bool {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        let project = fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let buildCache = project.appendingPathComponent(".texfast").path + "/"
        guard url.path.hasPrefix(project.path + "/"),
              !url.path.hasPrefix(buildCache) else { return false }
        if editor.fileURL == url { return true }
        if editor.hasUnsavedChanges {
            if editor.fileChangedOnDisk {
                status.stringValue = "Save or reload \(editor.fileURL?.lastPathComponent ?? "the current file") before switching"
                return false
            }
            guard editor.save() else {
                status.stringValue = "Could not save \(editor.fileURL?.lastPathComponent ?? "the current file")"
                return false
            }
        }
        let previous = editor.fileURL
        do { try editor.load(url) }
        catch {
            status.stringValue = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
        if let previous { lsp?.didClose(previous) }
        sourceWatcher?.stop()
        sourceWatcher = FileWatcher(url: url) { [weak self] in self?.sourceChangedOnDisk() }
        sourceWatcher?.start()
        editorPane.setDetail(url.lastPathComponent)
        window?.title = url == fileURL ? fileURL.lastPathComponent :
            "\(url.lastPathComponent) — \(fileURL.lastPathComponent)"
        files.select(url)
        outline.update([])
        editor.apply(diagnosticsByFile[url] ?? [])
        scheduleSymbolRefresh()
        window?.makeFirstResponder(editor.textView)
        return true
    }

    private func sourceChangedOnDisk() {
        guard editor.fileChangedOnDisk else { return }
        let name = editor.fileURL?.lastPathComponent ?? fileURL.lastPathComponent

        // Never silently discard the user's own unsaved typing.
        if editor.hasUnsavedChanges {
            status.stringValue = "\(name) changed on disk, but you have unsaved edits — File ▸ Reload from Disk to take theirs"
            return
        }
        guard editor.reloadFromDisk() else { return }
        builder.sourceDidChange()
        setPreviewState(.stale)
        status.stringValue = "\(name) reloaded from disk"
        scheduleSymbolRefresh()
        if editor.autoCompile { builder.build() }
    }

    @objc func reloadFromDisk(_ sender: Any?) {
        if editor.reloadFromDisk() {
            builder.sourceDidChange()
            setPreviewState(.stale)
            status.stringValue = "\(editor.fileURL?.lastPathComponent ?? fileURL.lastPathComponent) reloaded from disk"
            scheduleSymbolRefresh()
            if editor.autoCompile { builder.build() }
        } else {
            status.stringValue = "Already matches the file on disk"
        }
    }

    private func scheduleSymbolRefresh() {
        symbolWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let lsp, lsp.isRunning else { return }
            guard let sourceURL = editor.fileURL else { return }
            lsp.documentSymbols(sourceURL) { [weak self] items in
                guard self?.editor.fileURL == sourceURL else { return }
                self?.outline.update(items)
            }
        }
        symbolWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func forwardSync(line: Int, column: Int) {
        let shadow = builder.shadowURL
        let pdf = builder.pdfURL
        let activeSource = editor.fileURL ?? fileURL!
        let source = activeSource == fileURL ? shadow : activeSource
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let location = SyncTeX.forward(line: line, column: column, source: source, pdf: pdf) else { return }
            DispatchQueue.main.async { self?.preview.reveal(location) }
        }
    }

    // MARK: - actions

    @objc func saveDocument(_ sender: Any?) { editor.save() }

    @objc func toggleAutoCompile(_ sender: Any?) {
        let enabled = !editor.autoCompile
        editor.autoCompile = enabled
        UserDefaults.standard.set(enabled, forKey: autoCompileDefaultsKey)
        updateModeLabel()
        status.stringValue = enabled
            ? "Auto-compile on — builds when you stop typing"
            : "Auto-compile off — ⌘S to build"
    }

    private func updateModeLabel() {
        modeLabel.stringValue = editor.autoCompile ? "AUTO PREVIEW" : "MANUAL PREVIEW"
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutoCompile(_:)) {
            item.state = editor.autoCompile ? .on : .off
        }
        return true
    }

    @objc func buildNow(_ sender: Any?) {
        editor.save()
    }

    @objc func syncToPreview(_ sender: Any?) {
        let position = editor.caretLineAndColumn()
        forwardSync(line: position.line, column: position.column)
    }

    @objc func toggleOutline(_ sender: Any?) {
        splitController.splitViewItems.first?.animator().isCollapsed.toggle()
    }

    @objc func toggleProblems(_ sender: Any?) {
        problemsItem.isCollapsed.toggle()
        problemsButton.state = problemsItem.isCollapsed ? .off : .on
        if problemsItem.isCollapsed { problemsDismissed = true }
        else { problemsDismissed = false }
    }

    @objc func toggleTerminal(_ sender: Any?) {
        if terminalItem == nil {
            let controller = TerminalPaneController(projectDirectory: fileURL.deletingLastPathComponent())
            let pane = PaneController("TERMINAL", symbol: "terminal", content: controller)
            pane.setDetail(fileURL.deletingLastPathComponent().lastPathComponent)
            controller.onTitleChanged = { [weak pane] title in pane?.setDetail(title) }
            let item = NSSplitViewItem(viewController: pane)
            item.minimumThickness = 140
            item.maximumThickness = 600
            item.preferredThicknessFraction = 0.30
            workspaceController.addSplitViewItem(item)
            terminalController = controller
            terminalItem = item
        } else if let item = terminalItem {
            item.isCollapsed.toggle()
        }

        let isOpen = terminalItem?.isCollapsed == false
        terminalButton.state = isOpen ? .on : .off
        if isOpen {
            workspaceController.view.layoutSubtreeIfNeeded()
            terminalController?.startIfNeeded()
            if let window { terminalController?.focus(in: window) }
            // The split view can restore its previous responder while opening.
            DispatchQueue.main.async { [weak self] in
                guard let self, terminalItem?.isCollapsed == false, let window else { return }
                terminalController?.focus(in: window)
            }
        } else {
            window?.makeFirstResponder(editor.textView)
        }
    }

    /// Return an error if the pending buffer cannot safely become the source
    /// of the final PDF. A clean buffer leaves an externally edited file alone.
    func prepareForFinalRender() -> String? {
        terminalController?.stop()
        guard editor.hasUnsavedChanges else { return nil }
        if editor.fileChangedOnDisk {
            return "\(fileURL.lastPathComponent) changed on disk while you had unsaved edits. Save or reload it before quitting."
        }
        if !editor.save() { return "Could not save \(fileURL.lastPathComponent)." }
        return nil
    }

    func setEditingEnabled(_ enabled: Bool) {
        editor.textView.isEditable = enabled
    }

    func renderFinal(onProgress: @escaping (String, Double?) -> Void,
                     finished: @escaping (String?) -> Void) {
        let name = fileURL.lastPathComponent
        onProgress("\(name): preparing final PDF…", nil)
        builder.buildFinal(onPage: { pass, page, totalPages in
            let fraction = totalPages > 0 ? min(1, Double(page) / Double(totalPages)) : nil
            onProgress("\(name): pass \(pass), page \(page)\(totalPages > 0 ? " / ~\(totalPages)" : "")", fraction)
        }, finished: { [weak self] report in
            if report.error != nil {
                self?.updateCompileProblems(from: report)
                self?.revealProblemsAfterFailure()
            }
            finished(report.error)
        })
    }

    func shutDown() {
        terminalController?.stop()
        sourceWatcher?.stop()
        pdfWatcher?.stop()
        projectWatcher?.stop()
        lsp?.stop()
    }
}
