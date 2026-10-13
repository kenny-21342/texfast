import AppKit
import PDFKit
import TexFastCore

/// Exercise the actual Rust bridge and native PDF pane in a disposable bundle.
@main struct NativeSmoke {
    static func main() throws {
        Shell.ignoreBrokenPipes()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("texfast-pdfkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let main = root.appendingPathComponent("main.tex"), chapter = root.appendingPathComponent("chapter.tex")
        let original = "\\documentclass{article}\n\\usepackage{tikz}\n\\begin{document}\nHello world. Native preview with $x^2$.\n\n\\begin{tikzpicture}\\draw[blue,fill=cyan] (0,0) rectangle (1,1);\\end{tikzpicture}\n\\newpage\n\\input{chapter}\n\\end{document}\n"
        let included = "Second page: Unicode café.\n"
        try original.write(to: main, atomically: true, encoding: .utf8)
        try included.write(to: chapter, atomically: true, encoding: .utf8)
        let engine = RealtimeController(main: main)
        let pane = PDFPaneController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        pane.view.frame = NSRect(x: 0, y: 0, width: 800, height: 900)
        window.contentViewController = pane
        window.setContentSize(NSSize(width: 800, height: 900))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        var editing = false, finished = false, latestVersion = -1
        var recompileCount = 0, exportCount = 0, pageCount = 0
        var sawParagraph = false
        var testingRemoval = false
        var fastUnits = Set<Int>()
        var requestedOracle = false
        engine.onPagePreview = { page, units in pane.displayPagePreview(page, units: units) }
        engine.onPagePreviewReset = { units in pane.resetPagePreviews(units: units) }
        engine.onFast = { unit in
            fastUnits.insert(unit.id); pane.displayFast(unit)
            if fastUnits.count >= 2 && !requestedOracle {
                requestedOracle = true
                engine.requestLayout()
            }
        }
        pane.enableRealtime(recompile: { recompileCount += 1 }, export: { exportCount += 1 }, jump: { _, _, _ in })
        pane.onPageChanged = { _, total in pageCount = total }
        func finish(_ code: Int32, _ text: String) {
            guard !finished else { return }; finished = true
            print(text)
            engine.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let cache = RealtimeBuildCache(root: root, main: main)
                if !cache.persistent || cache.directory != engine.buildDirectory {
                    print("FAIL: shutdown did not release the reusable engine cache")
                    try? FileManager.default.removeItem(at: root)
                    exit(1)
                }
                cache.release()
                try? FileManager.default.removeItem(at: root)
                exit(code)
            }
        }
        func require(_ value: Bool, _ reason: String) -> Bool {
            if !value { finish(1, "FAIL: \(reason)") }
            return value
        }
        engine.onFailure = { reason in
            if testingRemoval && reason.contains("Source removed: chapter.tex") {
                finish(0, "PASS PDFKit: rapid independent edits, UTF-8, native drawing, page/zoom retention, corrupt/shrinking PDFs, toolbar, safe source removal")
            } else { finish(1, "FAIL engine: \(reason)") }
        }
        engine.onStatus = { text, _, issues in
            print(text)
            if text.contains("paragraph") { sawParagraph = true }
            if issues { finish(1, "FAIL engine status: \(text)") }
        }
        engine.onPDF = { data, revision, version in
            guard !finished, require(version > latestVersion, "layout versions must increase"),
                  require(pane.display(data, revision: revision), "PDFKit opens the engine PDF"),
                  let document = pane.pdfView.document else { return }
            latestVersion = version
            guard require(document.pageCount == 2 && pageCount == 2, "two pages and native page-count notification") else { return }
            if !editing {
                guard require(document.string?.contains("Hello world") == true, "initial selectable PDF text") else { return }
                editing = true
                pane.pdfView.autoScales = false
                pane.pdfView.scaleFactor = 1.1
                pane.pdfView.go(to: document.page(at: 1)!)
                // Rapid changes and a Unicode edit in an included file; none are saved to disk.
                engine.update(url: main, text: original.replacingOccurrences(of: "world", with: "one"))
                engine.update(url: main, text: original.replacingOccurrences(of: "world", with: "two"))
                engine.update(url: main, text: original.replacingOccurrences(of: "world", with: "native PDFKit"))
                engine.update(url: chapter, text: included.replacingOccurrences(of: "café", with: "naïve"))
                return
            }
            guard revision >= 5 else { return } // Background snapshots may advance before the latest unsaved edits.
            guard require(document.string?.contains("Hello native PDFKit") == true, "latest unsaved root edit"),
                  require(document.string?.contains("naïve") == true, "unsaved included-file UTF-8 edit"),
                  require(pane.pdfView.currentPage.map { document.index(for: $0) } == 1, "retain page two"),
                  require(abs(pane.pdfView.scaleFactor - 1.1) < 0.001 && !pane.pdfView.autoScales, "retain manual zoom"),
                  require(sawParagraph, "persistent fast path processed edits"),
                  require(fastUnits.count >= 2, "independent root and included edits both reach the fast preview"),
                  require((try? String(contentsOf: main, encoding: .utf8)) == original, "root source unchanged"),
                  require((try? String(contentsOf: chapter, encoding: .utf8)) == included, "included source unchanged") else { return }
            // Capture native PDF drawing, including math and TikZ, for visual inspection.
            guard let page = document.page(at: 0),
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 1200,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { finish(1, "No native bitmap context"); return }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
            let bounds = page.bounds(for: .mediaBox)
            context.scaleBy(x: 900 / bounds.width, y: 1200 / bounds.height)
            page.draw(with: .mediaBox, to: context)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { finish(1, "No PDF drawing"); return }
            do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
            catch { finish(1, "Screenshot: \(error)"); return }
            // A broken snapshot keeps the last good preview rather than blanking it.
            guard require(!pane.display(Data("bad PDF".utf8)), "reject corrupt PDF"),
                  require(pane.pdfView.document === document, "retain the last good PDF") else { return }
            let shorter = PDFDocument()
            shorter.insert(document.page(at: 0)!, at: 0)
            guard let shortData = shorter.dataRepresentation(), require(pane.display(shortData), "load shorter document"),
                  require(pane.pdfView.document?.pageCount == 1 && pane.pdfView.currentPage != nil, "clamp page after document shrinks") else { return }
            for button in descendants(pane.view).compactMap({ $0 as? NSButton }) {
                if button.title == "Recompile" || button.title == "Export PDF" { button.performClick(nil) }
            }
            guard require(recompileCount == 1 && exportCount == 1, "native toolbar actions") else { return }
            testingRemoval = true
            try! FileManager.default.removeItem(at: chapter)
            engine.refresh(activeURL: main, text: original.replacingOccurrences(of: "world", with: "native PDFKit"), forceLayout: true)
        }
        engine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { finish(1, "Timed out") }
        app.run()
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
