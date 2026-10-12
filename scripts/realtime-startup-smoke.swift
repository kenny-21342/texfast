import AppKit
import PDFKit
import TexFastCore

/// Measure the production window/bridge and exercise native cursor following.
@main final class StartupSmoke {
    static var runner: StartupSmoke!
    static func main() throws {
        Shell.ignoreBrokenPipes()
        NSApplication.shared.setActivationPolicy(.accessory)
        runner = try StartupSmoke()
        runner.next()
        NSApplication.shared.run()
    }
    let root: URL
    let main: URL
    let original: Data
    let actualProject: Bool
    let oldFollow = UserDefaults.standard.object(forKey: "TexFastFollowCursor")
    var controller: MainWindowController?
    var retired: [MainWindowController] = []
    var pdf: PDFView?
    var editor: EditorViewController?
    var phase = -1, step = 0, started = Date(), done = false
    var pdfSeen = false
    var engineReady = false
    var readySeconds: Double?
    var reports: [[String: Any]] = []
    var autoReveals = 0
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("texfast-startup-follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        actualProject = CommandLine.arguments.count > 2
        if actualProject { main = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath() }
        else {
            main = root.appendingPathComponent("main.tex")
            try "\\documentclass{article}\n\\begin{document}\nFirst target: café and $x^2$.\n\n\\newpage\nSecond target: native cursor follow.\n\n\\newpage\n\\input{chapter}\n\\end{document}\n".write(to: main, atomically: true, encoding: .utf8)
            try "Third target: included Unicode  naïve.\n".write(to: root.appendingPathComponent("chapter.tex"), atomically: true, encoding: .utf8)
        }
        original = try Data(contentsOf: main)
        UserDefaults.standard.set(true, forKey: "TexFastFollowCursor")
    }
    func next() {
        phase += 1
        if phase == 2 { finish(); return }
        print("Opening \(phase == 0 ? "initial" : "reopened") production window: \(main.path)"); fflush(stdout)
        started = Date(); pdfSeen = false; engineReady = false; readySeconds = nil; step = 0
        let window = MainWindowController(fileURL: main)
        controller = window; window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard let content = window.window?.contentView,
              let pdf = descendants(content).compactMap({ $0 as? PDFView }).first,
              let textView = descendants(content).compactMap({ $0 as? EditorTextView }).first,
              let editor = textView.delegate as? EditorViewController,
              let engine = window.realtime else { fail("No realtime production window"); return }
        self.pdf = pdf; self.editor = editor
        window.window?.makeFirstResponder(textView)
        let display = engine.onPDF, navigate = engine.onReveal
        engine.onFailure = { [weak self] in self?.fail($0) }
        engine.onEngineState = { [weak self] state in
            guard let self, state == "Ready", !engineReady else { return }
            engineReady = true; readySeconds = Date().timeIntervalSince(started)
            print(String(format: "Live LuaLaTeX ready: %.3f seconds", readySeconds!)); fflush(stdout)
            if actualProject && pdfSeen {
                if let readySeconds { reports[reports.count - 1]["engine_ready_seconds"] = readySeconds }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.retire() }
            }
        }
        engine.onPDF = { [weak self] data, revision, version in
            display?(data, revision, version)
            guard let self, !done, !pdfSeen else { return }
            pdfSeen = true
            let seconds = Date().timeIntervalSince(started)
            print(String(format: "PDFKit first engine PDF: %.3f seconds (%d pages)", seconds, pdf.document?.pageCount ?? 0)); fflush(stdout)
            reports.append(["phase": phase == 0 ? "initial" : "reopened", "preview_seconds": seconds,
                            "pages": pdf.document?.pageCount ?? 0, "source_bytes": original.count])
            if let readySeconds { reports[reports.count - 1]["engine_ready_seconds"] = readySeconds }
            if actualProject {
                if engineReady { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.retire() } }
                return
            }
            guard pdf.document?.pageCount == 3 else { fail("Expected three fixture pages"); return }
            // A selection-only change must follow; no text edit or save is involved.
            step = 1
            let range = (textView.string as NSString).range(of: "Second target")
            textView.setSelectedRange(NSRange(location: range.location + 8, length: 0))
        }
        engine.onReveal = { [weak self] location, force in
            navigate?(location, force)
            guard let self, !done, !actualProject else { return }
            if !force { autoReveals += 1 }
            if step == 1 {
                guard !force, location.page == 2 else { fail("Selection did not automatically follow page two"); return }
                step = 2
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard self.visible(location), window.window?.firstResponder === textView else { self.fail("Follow target is not visible or editor focus was stolen"); return }
                    guard pdf.document?.page(at: 1)?.annotations.isEmpty == true else { self.fail("Automatic following added a flashing marker"); return }
                    let origin = self.scrollOrigin()
                    engine.reveal(url: self.main, line: 6, column: 8, force: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        guard self.scrollOrigin() == origin else { self.fail("An already-visible caret scrolls the preview"); return }
                        self.toggleFollow(in: content)
                        let first = (textView.string as NSString).range(of: "First target")
                        textView.setSelectedRange(NSRange(location: first.location + 8, length: 0))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            // A pre-toggle query can still finish; PDFKit must ignore
                            // that automatic target while following is disabled.
                            let follow = self.descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Follow cursor" }
                            guard follow?.state == .off, self.scrollOrigin() == origin else {
                                self.fail("Follow off changed the preview scroll position")
                                return
                            }
                            self.step = 3
                            editor.onForwardSync?(3, 8)
                        }
                    }
                }
            } else if step == 3 {
                guard force, location.page == 1, visible(location) else { fail("Manual sync must work with Follow off"); return }
                step = 4
                toggleFollow(in: content)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.step = 5
                    engine.reveal(url: self.root.appendingPathComponent("chapter.tex"), line: 1, column: 12, force: false)
                }
            } else if step == 5 {
                guard !force, location.page == 3, visible(location) else { fail("Included-file cursor target did not reach page three"); return }
                step = 6
                print("PASS: selection-only following, viewport stability, retained focus, no auto marker, Follow toggle, manual sync, included source"); fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.retire() }
            }
        }
        let current = phase
        DispatchQueue.main.asyncAfter(deadline: .now() + (actualProject ? 180 : 30)) { [weak self] in
            guard let self, phase == current, !done else { return }
            fail("Startup/follow timed out")
        }
    }
    func visible(_ location: PDFLocation) -> Bool {
        guard let pdf, let page = pdf.document?.page(at: location.page - 1) else { return false }
        let bounds = page.bounds(for: .mediaBox)
        let point = pdf.convert(NSPoint(x: bounds.minX + location.x, y: bounds.maxY - location.y), from: page)
        return pdf.bounds.insetBy(dx: -1, dy: -1).contains(point)
    }
    func scrollOrigin() -> CGPoint? { pdf?.documentView?.enclosingScrollView?.contentView.bounds.origin }
    func toggleFollow(in view: NSView) {
        descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "Follow cursor" }?.performClick(nil)
    }
    func retire() {
        controller?.shutDown(); controller?.window?.orderOut(nil)
        if let controller { retired.append(controller) }
        controller = nil; pdf = nil; editor = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.next() }
    }
    func finish() {
        guard (try? Data(contentsOf: main)) == original else { fail("Source file changed"); return }
        guard let reopened = reports.last?["preview_seconds"] as? Double, reopened < 10 else { fail("Cached preview exceeded ten seconds"); return }
        let report: [String: Any] = ["method": "production MainWindowController construction to first engine PDF displayed by PDFKit; sources unchanged", "results": reports]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: production startup/reopen and source safety"); cleanExit(0)
    }
    func fail(_ message: String) { if !done { print("FAIL: \(message)"); cleanExit(1) } }
    func cleanExit(_ code: Int32) {
        done = true; controller?.shutDown()
        if let oldFollow { UserDefaults.standard.set(oldFollow, forKey: "TexFastFollowCursor") }
        else { UserDefaults.standard.removeObject(forKey: "TexFastFollowCursor") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { try? FileManager.default.removeItem(at: self.root); exit(code) }
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
