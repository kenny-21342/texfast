import AppKit
import TexFastCore

private let autoCompileDefaultsKey = "TexFastAutoCompile"

final class MainWindowController: NSWindowController, NSMenuItemValidation {

    var documentURL: URL { fileURL }

    private let editor = EditorViewController()
    private let preview = PDFPaneController()
    private let outline = OutlineViewController()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var splitController: NSSplitViewController!

    private var lsp: LSPClient?
    private var builder: BuildController!
    private var fileURL: URL!
    private var symbolWork: DispatchWorkItem?
    private var sourceWatcher: FileWatcher?
    private var pdfWatcher: FileWatcher?

    convenience init(fileURL: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = fileURL.lastPathComponent
        window.setFrameAutosaveName("TexFastMain")
        self.init(window: window)
        self.fileURL = fileURL
        assemble()
        open()
    }

    // MARK: - layout

    private func assemble() {
        let outlineItem = NSSplitViewItem(sidebarWithViewController: outline)
        outlineItem.minimumThickness = 160
        outlineItem.maximumThickness = 320
        outlineItem.canCollapse = true

        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 320
        let previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 320

        splitController = NSSplitViewController()
        splitController.addSplitViewItem(outlineItem)
        splitController.addSplitViewItem(editorItem)
        splitController.addSplitViewItem(previewItem)
        splitController.splitView.dividerStyle = .thin

        let root = NSView()
        let split = splitController.view
        split.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(split)
        root.addSubview(spinner)
        root.addSubview(status)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            spinner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            spinner.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            status.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)
        ])
        window?.contentView = root
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
        lsp?.onDiagnostics = { [weak self] diagnostics in
            self?.editor.apply(diagnostics)
            let errors = diagnostics.filter { $0.severity == 1 }.count
            if errors > 0 { self?.status.stringValue = "\(errors) error(s) — see the underlined lines" }
        }
        editor.lsp = lsp

        // Auto-compile is on unless the user has turned it off before.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: autoCompileDefaultsKey) == nil {
            defaults.set(true, forKey: autoCompileDefaultsKey)
        }
        editor.autoCompile = defaults.bool(forKey: autoCompileDefaultsKey)

        editor.onSave = { [weak self] in
            self?.sourceWatcher?.acknowledgeOwnWrite()
            self?.builder.build()
        }
        editor.onAutoSaveBlocked = { [weak self] in
            self?.status.stringValue = "\(self?.fileURL.lastPathComponent ?? "The file") changed on disk — auto-compile paused, ⌘S to overwrite"
        }
        editor.onTextChanged = { [weak self] _ in self?.scheduleSymbolRefresh() }
        editor.onForwardSync = { [weak self] line, column in self?.forwardSync(line: line, column: column) }

        preview.onReverseSync = { [weak self] line in
            self?.editor.jump(toLine: line)
            self?.window?.makeFirstResponder(self?.editor.textView)
        }
        outline.onSelect = { [weak self] line in self?.editor.jump(toLine: line) }

        builder.onState = { [weak self] state, message in
            guard let self else { return }
            status.stringValue = message
            if state == .idle { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        }
        builder.onFinished = { [weak self] _ in
            guard let self else { return }
            preview.reload()
            scheduleSymbolRefresh()
        }

        try? editor.load(fileURL)
        preview.load(builder.pdfURL)
        startWatching()
        scheduleSymbolRefresh()

        if builder.needsWarmUp {
            status.stringValue = "First open: building the figure cache (a few minutes, once)"
            builder.warmUp()
        }
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
        // unreadable until xdvipdfmx is done.
        pdfWatcher = FileWatcher(url: builder.pdfURL, interval: 0.6, settle: 0.7) { [weak self] in
            guard let self else { return }
            preview.reload()
            status.stringValue = "Preview updated \(Self.clock.string(from: Date()))"
        }
        pdfWatcher?.start()
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func sourceChangedOnDisk() {
        guard editor.fileChangedOnDisk else { return }
        let name = fileURL.lastPathComponent

        // Never silently discard the user's own unsaved typing.
        if editor.hasUnsavedChanges {
            status.stringValue = "\(name) changed on disk, but you have unsaved edits — File ▸ Reload from Disk to take theirs"
            return
        }
        guard editor.reloadFromDisk() else { return }
        status.stringValue = "\(name) reloaded from disk"
        scheduleSymbolRefresh()
        if editor.autoCompile { builder.build() }
    }

    @objc func reloadFromDisk(_ sender: Any?) {
        if editor.reloadFromDisk() {
            status.stringValue = "\(fileURL.lastPathComponent) reloaded from disk"
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
            lsp.documentSymbols(fileURL) { [weak self] items in self?.outline.update(items) }
        }
        symbolWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func forwardSync(line: Int, column: Int) {
        let shadow = builder.shadowURL
        let pdf = builder.pdfURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let location = SyncTeX.forward(line: line, column: column, shadow: shadow, pdf: pdf) else { return }
            DispatchQueue.main.async { self?.preview.reveal(location) }
        }
    }

    // MARK: - actions

    @objc func saveDocument(_ sender: Any?) { editor.save() }

    @objc func toggleAutoCompile(_ sender: Any?) {
        let enabled = !editor.autoCompile
        editor.autoCompile = enabled
        UserDefaults.standard.set(enabled, forKey: autoCompileDefaultsKey)
        status.stringValue = enabled
            ? "Auto-compile on — builds when you stop typing"
            : "Auto-compile off — ⌘S to build"
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

    func shutDown() {
        sourceWatcher?.stop()
        pdfWatcher?.stop()
        lsp?.stop()
    }
}
