import AppKit
import PDFKit
import TexFastCore

/// Compare native fast painting against the independently shipped background PDF.
@main final class FidelitySmoke {
    static var runner: FidelitySmoke!
    static func main() throws {
        Shell.ignoreBrokenPipes()
        NSApplication.shared.setActivationPolicy(.accessory)
        runner = try FidelitySmoke()
        runner.next()
        NSApplication.shared.run()
    }
    let root: URL
    let pane = PDFPaneController()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    let cases = [
        ("otf-math-color", "\\usepackage{xcolor}\n", "\\textcolor{red}{Hello world.} Math $x^2 + \\frac{a}{b}$ and rules.\n"),
        ("type1-math", "\\usepackage[T1]{fontenc}\n\\usepackage{lmodern}\n", "Hello world. Math $x^2 + \\frac{a}{b}$.\n"),
        ("native-tikz", "\\usepackage{tikz}\n", "\\begin{tikzpicture}\\draw[blue,fill=cyan] (0,0) rectangle (2,1);\\node at (1,.5) {Hello world};\\end{tikzpicture}\n"),
        ("bitmap", "\\usepackage{graphicx}\n", "Hello world. \\includegraphics[width=1cm]{image.png} Math $x^2$.\n")
    ]
    var index = -1, engine: RealtimeController?, original = "", editing = false, fast: NSBitmapImageRep?, done = false
    var output: [[String: Any]] = []
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("texfast-fidelity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pane.view.frame = NSRect(x: 0, y: 0, width: 800, height: 900)
        window.contentViewController = pane
        window.setContentSize(NSSize(width: 800, height: 900)); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func next() {
        engine?.stop(); engine = nil
        index += 1
        if index == cases.count { finish(0, "PASS: all native fast drawings match the shipped PDF within one pixel"); return }
        let (name, setup, body) = cases[index]
        print("Checking \(name)"); fflush(stdout)
        let folder = root.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        for (color, rect) in [(NSColor.systemBlue, CGRect(x: 0, y: 0, width: 8, height: 8)),
                              (NSColor.red, CGRect(x: 8, y: 0, width: 8, height: 8)),
                              (NSColor.green, CGRect(x: 0, y: 8, width: 8, height: 8)),
                              (NSColor.magenta, CGRect(x: 8, y: 8, width: 8, height: 8))] {
            cg.setFillColor(color.cgColor); cg.fill(rect)
        }
        try! bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("image.png"))
        original = "\\documentclass{article}\n\(setup)\\begin{document}\n\(body)\nSecond paragraph stays in place.\n\\end{document}\n"
        let url = folder.appendingPathComponent("main.tex")
        try! original.write(to: url, atomically: true, encoding: .utf8)
        let session = RealtimeController(main: url)
        engine = session; editing = false; fast = nil
        session.onFailure = { [weak self] text in self?.finish(1, text) }
        session.onStatus = { [weak self] text, _, issues in if issues { self?.finish(1, text) } }
        session.onFast = { [weak self] unit in
            guard let self, !done, let document = pane.pdfView.document else { return }
            pane.displayFast(unit)
            fast = raster(document, overlay: true)
        }
        session.onPDF = { [weak self] data, revision, _ in
            guard let self, !done, let reference = PDFDocument(data: data) else { return }
            if !editing {
                guard pane.display(data, revision: revision) else { finish(1, "Initial PDF invalid"); return }
                editing = true
                session.update(url: url, text: original.replacingOccurrences(of: "world", with: "swift"))
                return
            }
            guard revision >= 2, let fast else { finish(1, "No fast drawing for \(name)"); return }
            let expected = raster(reference, overlay: false)
            let (forward, backward) = match(fast, expected)
            print(String(format: "%@: fast->PDF %.3f%%, PDF->fast %.3f%%", name, forward*100, backward*100)); fflush(stdout)
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try! fast.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name+"-fast.png"))
            try! expected.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name+"-pdf.png"))
            output.append(["case": name, "fast_to_pdf": forward, "pdf_to_fast": backward])
            guard forward >= 0.99, backward >= 0.99 else { finish(1, "Native/PDF fidelity mismatch in \(name)"); return }
            guard (try? String(contentsOf: url, encoding: .utf8)) == original else { finish(1, "Source changed"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.next() }
        }
        session.start()
        let current = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.index == current && self?.done == false { self?.finish(1, "Timed out on \(name)") }
        }
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
        guard !done else { return }; done = true
        print(text); fflush(stdout)
        engine?.stop()
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: directory.appendingPathComponent("results.json")) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in try? FileManager.default.removeItem(at: root); exit(code) }
    }
}
