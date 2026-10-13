import AppKit
import PDFKit
import TexFastCore

/// Production editor insertion -> actual native overlay draw, not engine timing alone.
@main final class LatencySmoke {
    static var runner: LatencySmoke!
    static func main() throws {
        Shell.ignoreBrokenPipes()
        NSApplication.shared.setActivationPolicy(.accessory)
        runner = try LatencySmoke()
        runner.nextCase()
        NSApplication.shared.run()
    }
    let root: URL
    let cases: [(String, Int, String)] = [
        ("OpenType + math, 10 pages", 10, ""),
        ("Type 1 + math, 10 pages", 10, "\\usepackage[T1]{fontenc}\n\\usepackage{lmodern}\n"),
        ("OpenType + math, 100 pages", 100, ""),
        ("OpenType + math, 300 pages", 300, "")
    ]
    var caseIndex = -1
    var retiredControllers: [MainWindowController] = []
    var controller: MainWindowController?
    var editor: EditorViewController?
    var preview: PDFView?
    var checkTimer: Timer?
    var waitingSince: UInt64 = 0
    var start: UInt64?
    var sample = 0
    var times: [Double] = []
    var reports: [[String: Any]] = []
    var stopped = false
    var engineReady = false
    var lastStatus = "", lastFast = 0
    var source = ""
    var currentRoot: URL!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("texfast-latency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func nextCase() {
        controller?.shutDown(); controller?.window?.orderOut(nil)
        if let controller { retiredControllers.append(controller) }
        editor = nil; preview = nil; controller = nil
        caseIndex += 1
        if caseIndex == cases.count { finish(); return }
        let (name, pages, setup) = cases[caseIndex]
        currentRoot = root.appendingPathComponent("case-\(caseIndex)")
        try! FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        let body = String(repeating: "This paragraph provides realistic document text and math $a^2+b^2=c^2$. ", count: 6)
        source = "\\documentclass{article}\n\(setup)\\begin{document}\nLatency target: native edits with $x^2$ and punctuation.\n\n\(body)\n"
        for page in 1..<pages { source += "\\newpage\nPage \(page + 1). \(body)\n\n\(body)\n" }
        source += "\\end{document}\n"
        let url = currentRoot.appendingPathComponent("main.tex")
        try! source.write(to: url, atomically: true, encoding: .utf8)
        print("Opening \(name)"); fflush(stdout)
        engineReady = false
        controller = MainWindowController(fileURL: url)
        controller?.realtime?.onEngineState = { [weak self] state in
            if state == "Ready" { self?.engineReady = true }
        }
        if let engine = controller?.realtime {
            let status = engine.onStatus, fast = engine.onFast
            engine.onStatus = { [weak self] text, busy, issues in self?.lastStatus = text; status?(text, busy, issues) }
            engine.onFast = { [weak self] unit in self?.lastFast = unit.revision; fast?(unit) }
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        waitingSince = DispatchTime.now().uptimeNanoseconds
        sample = 0; times.removeAll(); start = nil
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { return }
            if DispatchTime.now().uptimeNanoseconds - waitingSince > 60_000_000_000 { fail("Preview never became ready"); return }
            guard engineReady, let window = controller?.window, let content = window.contentView,
                  let pdf = descendants(content).compactMap({ $0 as? PDFView }).first,
                  pdf.document?.pageCount == pages,
                  let provider = pdf.pageOverlayViewProvider as? NativeLiveOverlay,
                  let textView = descendants(content).compactMap({ $0 as? EditorTextView }).first,
                  let editorController = textView.delegate as? EditorViewController else { return }
            timer.invalidate(); checkTimer = nil
            editor = editorController; preview = pdf
            editorController.autoCompile = true
            editorController.autoCompileDelay = 1000 // measure unsaved input without autosave I/O
            provider.onPaint = { [weak self] _, revision, time in self?.painted(time, revision: revision) }
            provider.onPreviewPaint = { [weak self] page, revision, time in
                if page == 1 { self?.painted(time, revision: revision) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.insert() }
        }
    }
    func insert() {
        guard !stopped, let editor, start == nil else { return }
        let range = (editor.textView.string as NSString).range(of: "Latency target:")
        guard range.location != NSNotFound else { fail("No editor target"); return }
        editor.textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        start = DispatchTime.now().uptimeNanoseconds
        editor.textView.insertText("a", replacementRange: editor.textView.selectedRange())
        let timestamp = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.start == timestamp, timestamp != nil {
                guard let self else { return }
                let page = preview?.currentPage.flatMap { self.preview?.document?.index(for: $0) } ?? -1
                fail("No native paragraph draw: sample \(sample), fast revision \(lastFast), page \(page), status \(lastStatus)")
            }
        }
    }
    func painted(_ time: UInt64, revision: Int) {
        guard let start, !stopped, revision >= sample + 2 else { return }
        self.start = nil
        let elapsed = Double(time - start) / 1_000_000
        if sample >= 5 { times.append(elapsed) } // exclude five warm-up insertions
        sample += 1
        if sample < 45 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.insert() }
            return
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2], p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        let max = sorted.last!
        print(String(format: "%@: median %.2f ms, p95 %.2f ms, max %.2f ms (%d insertions)", cases[caseIndex].0, median, p95, max, sorted.count))
        fflush(stdout)
        reports.append(["case": cases[caseIndex].0, "pages": cases[caseIndex].1, "source_bytes": source.utf8.count,
                        "samples_ms": times, "median_ms": median, "p95_ms": p95, "max_ms": max])
        guard p95 < 50 else { fail("p95 latency exceeds 50 ms"); return }
        controller?.shutDown()
        guard (try? String(contentsOf: currentRoot.appendingPathComponent("main.tex"), encoding: .utf8)) == source else { fail("Benchmark changed source on disk"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.nextCase() }
    }
    func finish() {
        stopped = true
        let report: [String: Any] = ["method": "NSTextView insertion through production editor -> native PDFKit overlay draw; warm runs exclude 5 insertions; compositor/keyboard scan-out not measured",
                                     "os": ProcessInfo.processInfo.operatingSystemVersionString, "results": reports]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: all warm p95 insertion-to-draw latencies below 50 ms")
        cleanExit(0)
    }
    func fail(_ text: String) { if !stopped { stopped = true; print("FAIL: \(text)"); cleanExit(1) } }
    func cleanExit(_ code: Int32) {
        checkTimer?.invalidate(); controller?.shutDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in try? FileManager.default.removeItem(at: root); exit(code) }
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func controllers(_ controller: NSViewController) -> [NSViewController] { [controller] + controller.children.flatMap(controllers) }
}
