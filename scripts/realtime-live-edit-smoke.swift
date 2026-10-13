import AppKit
import PDFKit
import TexFastCore

/// Verify visible unsaved editing, including a paragraph absent from the base PDF.
@main final class LiveEditSmoke {
    static var runner: LiveEditSmoke!
    static func main() throws {
        Shell.ignoreBrokenPipes()
        NSApplication.shared.setActivationPolicy(.accessory)
        runner = try LiveEditSmoke(); runner.open(); NSApplication.shared.run()
    }
    let scratch: URL, main: URL, original: String, actual: Bool
    var controller: MainWindowController!, editor: EditorViewController!, pdf: PDFView!
    var ready = false, hasPDF = false, started = false, done = false
    var stage = 0, inserted = 0, pdfRevision = 0, firstID: Int?, newID: Int?
    var targetPage = 1, pagePaints = 0
    var painted = Set<Int>(), fast = Set<Int>(), stalePDFs = 0
    var splitBeforePDF = false, startTimes: [Int: UInt64] = [:], times: [Double] = []
    let oldFollow = UserDefaults.standard.object(forKey: "TexFastFollowCursor")
    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("texfast-live-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        actual = CommandLine.arguments.count > 2
        if actual { main = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath() }
        else {
            main = scratch.appendingPathComponent("main.tex")
            let body = "A homogenous equation might not be valid. The native editor should draw each change before a background PDF."
            var text = "\\documentclass{article}\n\\begin{document}\n\(body)\n\nSecond paragraph stays visible.\n"
            for i in 2...100 { text += "\\newpage\nPage \(i). \(body)\n\nAnother paragraph.\n" }
            text += "\\end{document}\n"
            try text.write(to: main, atomically: true, encoding: .utf8)
        }
        original = try String(contentsOf: main, encoding: .utf8)
        UserDefaults.standard.set(true, forKey: "TexFastFollowCursor")
    }
    func open() {
        controller = MainWindowController(fileURL: main); controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        let content = controller.window!.contentView!
        pdf = descendants(content).compactMap { $0 as? PDFView }.first!
        editor = descendants(content).compactMap { $0 as? EditorTextView }.first!.delegate as? EditorViewController
        editor.autoCompile = true; editor.autoCompileDelay = 1000 // never save this benchmark's edits
        controller.window?.makeFirstResponder(editor.textView)
        guard let engine = controller.realtime, let overlay = pdf.pageOverlayViewProvider as? NativeLiveOverlay else { finish(1, "No live production preview"); return }
        let display = engine.onPDF, live = engine.onFast, status = engine.onStatus
        engine.onEngineState = { [self] state in if state == "Ready" { ready = true; begin() } }
        engine.onFailure = { [self] reason in finish(1, reason) }
        engine.onStatus = { [self] text, busy, issues in status?(text, busy, issues); if issues { finish(1, text) } }
        engine.onPDF = { [self] data, revision, version in
            if stage == 3 && revision < inserted + 3 { stalePDFs += 1 }
            pdfRevision = revision; display?(data, revision, version); hasPDF = true; begin()
        }
        engine.onFast = { [self] unit in
            fast.insert(unit.revision)
            if stage == 1 { firstID = unit.id; targetPage = unit.pages.keys.min() ?? 1 }
            if stage == 2 && unit.id != firstID {
                newID = unit.id; splitBeforePDF = pdfRevision < unit.revision
            }
            live?(unit)
        }
        overlay.onPreviewPaint = { [self] page, revision, time in
            guard stage == 3, page == targetPage, revision >= 4 else { return }
            pagePaints += 1; painted.insert(revision)
            if let start = startTimes.removeValue(forKey: revision) { times.append(Double(time - start)/1_000_000) }
        }
        overlay.onPaint = { [self] id, revision, time in
            guard !done else { return }
            painted.insert(revision)
            if let start = startTimes.removeValue(forKey: revision) { times.append(Double(time - start) / 1_000_000) }
            if stage == 1 && id == firstID {
                stage = 2
                DispatchQueue.main.async { [self] in split() }
            } else if stage == 2 && id == newID {
                guard splitBeforePDF, pdfRevision < revision else { finish(1, "New paragraph waited for a full PDF"); return }
                print("PASS: newly split paragraph visibly painted before any PDF containing it"); fflush(stdout)
                stage = 3
                DispatchQueue.main.async { [self] in type() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 80) { [self] in finish(1, "Timed out waiting for live painting, stage \(stage), fast \(fast.sorted()), painted \(painted.sorted())") }
    }
    func begin() {
        guard ready, hasPDF, !started else { return }; started = true
        let range = (editor.textView.string as NSString).range(of: "A homogenous equation might not be valid")
        guard range.location != NSNotFound else { finish(1, "No target paragraph"); return }
        editor.textView.setSelectedRange(NSRange(location: range.location + 8, length: 0))
        // Let native cursor following bring the edited page into the viewport.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            stage = 1
            replace("A homogenous equation might not be valid", "A homogenous equation might not be correct", revision: 2)
        }
    }
    func replace(_ before: String, _ after: String, revision: Int) {
        let range = (editor.textView.string as NSString).range(of: before)
        guard range.location != NSNotFound else { finish(1, "Missing edit target"); return }
        startTimes[revision] = DispatchTime.now().uptimeNanoseconds
        editor.textView.insertText(after, replacementRange: range)
    }
    func split() { replace("A homogenous equation might not be correct", "A homogenous equation.\n\nLive target might not be correct", revision: 3) }
    func type() {
        guard !done else { return }
        if inserted == 60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                guard painted.contains(63), painted.filter({ $0 >= 4 }).count >= 40 else { finish(1, "Continuous typing did not paint promptly: last \(painted.sorted().last ?? 0), count \(painted.filter({ $0 >= 4 }).count), pages \(pagePaints)"); return }
                guard (try? String(contentsOf: main, encoding: .utf8)) == original else { finish(1, "Source changed on disk"); return }
                let sorted = times.sorted(), p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
                print(String(format: "PASS: %d/60 unsaved typing revisions painted; p95 %.2f ms; %d intervening stale PDFs; %d pages", painted.filter({ $0 >= 4 }).count, p95, stalePDFs, pdf.document?.pageCount ?? 0))
                let report: [String: Any] = ["actual_project": actual, "source_bytes": original.utf8.count, "pages": pdf.document?.pageCount ?? 0,
                    "split_painted_before_pdf": splitBeforePDF, "typing_revisions": 60, "painted_revisions": painted.sorted(), "stale_pdfs": stalePDFs, "page_preview_paints": pagePaints,
                    "samples_ms": times, "p95_ms": p95, "sources_unchanged": true]
                let output = URL(fileURLWithPath: CommandLine.arguments[1])
                try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output)
                finish(0, "PASS: realtime visible editing without saving or requesting a PDF per edit")
            }
            return
        }
        let range = (editor.textView.string as NSString).range(of: "Live target")
        inserted += 1; startTimes[inserted + 3] = DispatchTime.now().uptimeNanoseconds
        // Spaces force line-count changes too, exercising engine-driven reflow.
        editor.textView.insertText(" a", replacementRange: NSRange(location: NSMaxRange(range), length: 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in type() }
    }
    func finish(_ code: Int32, _ message: String) {
        guard !done else { return }; done = true; print(message); fflush(stdout)
        controller?.shutDown()
        if let oldFollow { UserDefaults.standard.set(oldFollow, forKey: "TexFastFollowCursor") }
        else { UserDefaults.standard.removeObject(forKey: "TexFastFollowCursor") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in try? FileManager.default.removeItem(at: scratch); exit(code) }
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
