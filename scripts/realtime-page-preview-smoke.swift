import AppKit
import PDFKit
import TexFastCore

/// Real PagePreview drawing before a slow suffix, final-PDF fidelity and rollback.
@main final class PagePreviewSmoke {
    static var runner: PagePreviewSmoke!
    static func main() throws {
        Shell.ignoreBrokenPipes(); NSApplication.shared.setActivationPolicy(.accessory)
        runner = try PagePreviewSmoke(); runner.engine.start(); NSApplication.shared.run()
    }
    let root: URL, main: URL, original: String
    let pane = PDFPaneController()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    let engine: RealtimeController
    var phase = 0, done = false, reset = false, issues = false
    var text = "", snapshot: NSBitmapImageRep?, fullRevision = 0
    var growthSent = false, growthPainted = false, growthSince: UInt64 = 0
    var began: UInt64 = 0, firstPaint: UInt64?, errorPreviewPainted = false
    var report: [String: Any] = [:]
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("texfast-page-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        main = root.appendingPathComponent("main.tex")
        original = "\\documentclass{article}\n\\usepackage[paperwidth=240pt,paperheight=320pt,margin=20pt]{geometry}\n\\begin{document}\nAnchor words in a paragraph that can grow to wrap across additional lines.\n\nFollowing text moves when the paragraph grows.\n\n\\newpage\n\\directlua{local t=os.clock()+1.0; while os.clock()<t do end}\n\\IfFileExists{failure.flag}{\\undefinedpreviewmacro}{}\nSlow suffix.\n\\end{document}\n"
        text = original; try original.write(to: main, atomically: true, encoding: .utf8)
        engine = RealtimeController(main: main)
        pane.view.frame = NSRect(x: 0, y: 0, width: 650, height: 900)
        window.contentViewController = pane; window.setContentSize(NSSize(width: 650, height: 900)); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        engine.onFailure = { [self] in finish(1, $0) }
        engine.onStatus = { [self] status, _, hasIssues in
            if hasIssues { issues = true; checkRollback(); return }
            if phase == 0 && status.contains("layout converged") { phase = 1; edit(" extra words", count: 70) }
        }
        engine.onFast = { [self] in pane.displayFast($0) }
        engine.onPagePreview = { [self] preview, units in
            pane.displayPagePreview(preview, units: units)
        }
        engine.onPagePreviewReset = { [self] units in
            pane.resetPagePreviews(units: units)
            if phase == 2 { reset = true; checkRollback() }
        }
        pane.liveOverlay.onPaint = { [self] _, revision, time in
            if phase == 2 && growthSent && revision >= 4 && !growthPainted {
                let ms = Double(time - growthSince)/1_000_000
                guard ms < 50 else { finish(1, "Growing live text waited for background pagination: \(ms) ms"); return }
                growthPainted = true; report["growth_paint_ms"] = ms
                print(String(format: "PASS: a newer growing paragraph stays live (%.2f ms)", ms)); fflush(stdout)
                checkRollback()
            }
        }
        pane.liveOverlay.onPreviewPaint = { [self] page, revision, time in
            guard page == 1 else { return }
            if phase == 1 && revision >= 2 && firstPaint == nil {
                guard fullRevision < revision else { finish(1, "Page preview arrived after the full PDF"); return }
                firstPaint = time
                snapshot = raster(pane.pdfView.document!, overlay: true)
                print("PASS: native complete-page drawing painted before the slow suffix finished"); fflush(stdout)
            } else if phase == 2 && revision >= 3 {
                errorPreviewPainted = true
                if !growthSent {
                    growthSent = true
                    DispatchQueue.main.async { [self] in growthSince = DispatchTime.now().uptimeNanoseconds; edit(" more growth", count: 10) }
                }
            }
        }
        engine.onPDF = { [self] data, revision, _ in
            guard let reference = PDFDocument(data: data) else { finish(1, "Invalid PDF"); return }
            fullRevision = revision
            if phase == 1 && revision >= 2 {
                guard let firstPaint, let snapshot else { finish(1, "No native page-preview paint"); return }
                let now = DispatchTime.now().uptimeNanoseconds
                let lead = Double(now - firstPaint) / 1_000_000
                guard lead >= 400 else { finish(1, "Page progress did not precede the slow suffix"); return }
                let expected = raster(reference, overlay: false), (forward, backward) = match(snapshot, expected)
                guard forward >= 0.99, backward >= 0.99 else { finish(1, "Page-preview/final-PDF fidelity mismatch: \(forward), \(backward)"); return }
                print(String(format: "PASS: page preview leads the full PDF by %.1f ms; fidelity %.3f%% / %.3f%%", lead, forward*100, backward*100)); fflush(stdout)
                report = ["preview_ms": Double(firstPaint - began)/1_000_000, "full_pdf_ms": Double(now - began)/1_000_000,
                          "lead_ms": lead, "preview_to_pdf": forward, "pdf_to_preview": backward]
                guard pane.display(data, revision: revision) else { finish(1, "Full PDF unavailable"); return }
                // Begin after this completed pass is also reported as converged.
                phase = 3
            } else { _ = pane.display(data, revision: revision) }
        }
        let normalStatus = engine.onStatus
        engine.onStatus = { [self] message, busy, hasIssues in
            normalStatus?(message, busy, hasIssues)
            if phase == 3 && message.contains("layout converged") {
                phase = 2
                try! Data().write(to: root.appendingPathComponent("failure.flag"))
                edit(" another word", count: 8)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [self] in finish(1, "Timed out at phase \(phase), reset \(reset), issues \(issues)") }
    }
    func edit(_ words: String, count: Int) {
        began = DispatchTime.now().uptimeNanoseconds
        text = text.replacingOccurrences(of: "Anchor", with: "Anchor" + String(repeating: words, count: count))
        engine.update(url: main, text: text)
    }
    func checkRollback() {
        guard phase == 2, reset, issues else { return }
        guard growthPainted else { return }
        guard errorPreviewPainted else { finish(1, "The failed pass had no early visible page to roll back"); return }
        guard (try? String(contentsOf: main, encoding: .utf8)) == original else { finish(1, "Source changed"); return }
        report["error_preview_painted"] = true; report["rollback"] = true; report["source_unchanged"] = true
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        finish(0, "PASS: failed suffix rolls back its preview, retains diagnostics, and leaves source unchanged")
    }
    func raster(_ document: PDFDocument, overlay: Bool) -> NSBitmapImageRep {
        let page = document.page(at: 0)!, size = page.bounds(for: .mediaBox).size
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 1600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
        context.scaleBy(x: 1200/size.width, y: 1600/size.height)
        page.draw(with: .mediaBox, to: context)
        if overlay { context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1); pane.liveOverlay.draw(page: 1, in: context) }
        return bitmap
    }
    func match(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (Double, Double) {
        func coverage(_ x: NSBitmapImageRep, _ y: NSBitmapImageRep) -> Double {
            let src = x.bitmapData!, dst = y.bitmapData!, w = x.pixelsWide, h = x.pixelsHigh
            var ink = 0, matching = 0
            for py in 0..<h { for px in 0..<w {
                let p = py*x.bytesPerRow + px*4
                if min(src[p],src[p+1],src[p+2]) >= 180 { continue }
                ink += 1
                var found = false
                for dy in -1...1 where py+dy >= 0 && py+dy < h {
                    for dx in -1...1 where px+dx >= 0 && px+dx < w {
                        let q = (py+dy)*y.bytesPerRow + (px+dx)*4
                        if min(dst[q],dst[q+1],dst[q+2]) < 180 &&
                            max(abs(Int(src[p])-Int(dst[q])),abs(Int(src[p+1])-Int(dst[q+1])),abs(Int(src[p+2])-Int(dst[q+2]))) < 80 { found = true }
                    }
                }
                if found { matching += 1 }
            } }
            return ink > 100 ? Double(matching)/Double(ink) : 0
        }
        return (coverage(a,b),coverage(b,a))
    }
    func finish(_ code: Int32, _ text: String) {
        guard !done else { return }; done = true; print(text); fflush(stdout); engine.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in try? FileManager.default.removeItem(at: root); exit(code) }
    }
}
