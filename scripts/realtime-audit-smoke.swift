import AppKit
import PDFKit
import TexFastCore

@main struct AuditSmoke {
    static func main() throws {
        Shell.ignoreBrokenPipes()
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("texfast-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if !condition { failures += 1 }
        }
        let sp = 65781.76
        let fragment: [String: Any] = ["page": 1, "first_line": 1, "last_line": 1, "x": 0, "baselines": [10 * sp]]
        func row(_ items: [[Any]]) -> [String: Any] {
            ["unit": 1, "x": 0, "y": 10 * sp, "w": 50 * sp, "h": 10 * sp, "d": 0, "items": items]
        }
        func layout(_ dl: [String: Any]) -> [String: Any] {
            ["pages_total": 1, "pages_changed": [["page": 1, "dl": dl]],
             "placements": [["par_id": 1, "fragments": [fragment]]]]
        }
        func event(_ dl: [String: Any]) -> [String: Any] {
            ["par_id": 1, "status": "ok", "versions": ["source_revision": 2], "dl": dl, "fragments": [fragment]]
        }
        let renderer = NativeLiveRenderer(root: root)
        let colors: [[Any]] = [["c", 0, 0, "1 0 0 rg"], ["c", 0, 1, "0 0 1 rg"],
                               ["c", 0, 0, "0 1 0 rg"], ["c", 0, 2, ""], ["r", 0, 0, 20 * sp, 10 * sp]]
        let dl: [String: Any] = ["lines": [row(colors)]]
        renderer.installLayout(layout(dl))
        let unit = renderer.prepare(event(dl))
        var restoredRed = false
        if let operations = unit?.pages[1]?.drawing {
            for operation in operations {
                if case let .fill(_, color, _) = operation {
                    restoredRed = color.components == [1, 0, 0, 1]
                }
            }
        }
        check(restoredRed, "nested color-stack set/pop restores the outer color")
        let removed = renderer.prepare(["par_id": 1, "status": "removed", "versions": ["source_revision": 3], "dl": NSNull()])
        check(removed?.pages[1]?.drawing.isEmpty == true && removed?.pages[1]?.masks.isEmpty == false,
              "a removed unit with no display list clears its previous drawing")
        var added = event(dl); added["par_id"] = 2
        check(renderer.prepare(added)?.pages[1]?.drawing.isEmpty == false,
              "a newly inserted paragraph draws before it exists in any full PDF")
        var unplaced = added; unplaced["fragments"] = []
        check(renderer.prepare(unplaced) == nil, "an unplaced new unit cannot report a successful live drawing")
        var unsupported = dl; unsupported["flags"] = ["unknown-operation": true]
        check(renderer.prepare(event(unsupported)) == nil, "unsupported operations preserve the complete PDF")
        let sparseRenderer = NativeLiveRenderer(root: root)
        sparseRenderer.installLayout(layout(dl))
        var movedRow = row(colors); movedRow["x"] = 20 * sp
        let movedDL: [String: Any] = ["lines": [movedRow]]
        sparseRenderer.recordLayoutPages(["pages_changed": [["page": 1, "dl": movedDL]]])
        let beforeCommit = sparseRenderer.prepare(["par_id": 1, "status": "removed", "versions": ["source_revision": 3]])
        check(beforeCommit?.pages[1]?.bounds.minX == -0.75, "a stale page delta does not move the displayed PDF masks")
        var movedFragment = fragment; movedFragment["x"] = 20 * sp
        sparseRenderer.installLayout(["pages_total": 1, "pages_changed": [], "placements": [["par_id": 1, "fragments": [movedFragment]]]])
        let afterCommit = sparseRenderer.prepare(["par_id": 1, "status": "removed", "versions": ["source_revision": 4]])
        check(afterCommit?.pages[1]?.bounds.minX == 19.25, "an accepted sparse layout includes deltas from skipped stale passes")

        // Count real subprocess lookups, including repeated glyphs referencing one missing font.
        let kpse = root.appendingPathComponent("kpsewhich"), calls = root.appendingPathComponent("calls")
        try "#!/bin/sh\nprintf x >> '\(calls.path)'\nexit 1\n".write(to: kpse, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kpse.path)
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", root.path, 1)
        let fontRenderer = NativeLiveRenderer(root: root)
        let glyphs = Array(repeating: ["g", 1, 65, 1, 0, 10 * sp, 0, 0] as [Any], count: 20)
        let fontDL: [String: Any] = ["fonts": ["1": ["filename": "missing.otf", "size": 10 * sp]], "lines": [row(glyphs)]]
        fontRenderer.installLayout(layout(fontDL))
        check((try? Data(contentsOf: calls).count) == 1, "missing-font lookup happens once per layout, not per glyph")
        check(fontRenderer.prepare(event(fontDL)) == nil, "missing fonts use the full PDF path")
        setenv("PATH", oldPath, 1)
        let fontPath = Shell.run("/Library/TeX/texbin/kpsewhich", ["lmroman10-regular.otf"], cwd: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fontPath), to: root.appendingPathComponent("missing.otf"))
        fontRenderer.installLayout(layout(fontDL))
        check(fontRenderer.prepare(event(fontDL)) != nil, "an unavailable font is retried when a complete layout arrives")

        // The overlay must order revisions per unit and respect the complete-PDF floor.
        let overlay = NativeLiveOverlay(), document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 100, height: 100), for: .mediaBox)
        document.insert(page, at: 0); overlay.install(document: document, revision: 1)
        check(overlay.pdfView(PDFView(), overlayViewFor: PDFPage()) == nil, "a page outside the document has no overlay")
        func solid(_ id: Int, _ revision: Int, _ color: NSColor, _ x: CGFloat) -> NativeLiveUnit {
            let rect = CGRect(x: x, y: 0, width: 10, height: 10)
            return NativeLiveUnit(id: id, revision: revision, pages: [1: NativeLivePage(masks: [rect], drawing: [.fill(CGPath(rect: rect, transform: nil), color.cgColor, false)])])
        }
        overlay.apply(solid(1, 4, .red, 0)); overlay.apply(solid(1, 2, .blue, 0))
        overlay.apply(solid(2, 3, .green, 20))
        func painted(_ x: Int) -> NSColor {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            overlay.draw(page: 1, in: context)
            return bitmap.colorAt(x: x, y: 95)!.usingColorSpace(.deviceRGB)!
        }
        check(painted(5).redComponent > 0.99 && painted(25).greenComponent > 0.99,
              "older same-unit events are ignored while independent older revisions still draw")
        overlay.install(document: document, revision: 4); overlay.apply(solid(1, 3, .blue, 0))
        check(painted(5).redComponent > 0.99 && painted(5).blueComponent > 0.99, "a committed PDF clears and rejects older provisional updates")
        page.rotation = 90
        overlay.apply(solid(1, 5, .blue, 0))
        check(overlay.pdfView(PDFView(), overlayViewFor: page) == nil && painted(5).redComponent > 0.99,
              "rotated pages retain the complete PDF instead of misplacing overlays")
        page.rotation = 0
        page.setBounds(CGRect(x: 10, y: 10, width: 80, height: 80), for: .cropBox)
        overlay.apply(solid(1, 6, .blue, 0))
        check(overlay.pdfView(PDFView(), overlayViewFor: page) == nil && painted(5).redComponent > 0.99,
              "cropped pages retain the complete PDF instead of misplacing overlays")
        page.setBounds(page.bounds(for: .mediaBox), for: .cropBox)
        overlay.apply(solid(1, 7, .blue, 0))
        check(painted(5).redComponent < 0.1, "the supported page draws the latest provisional edit")
        overlay.clear()
        check(painted(5).redComponent > 0.99 && painted(5).blueComponent > 0.99,
              "fallback clears provisional overlays even when no replacement PDF exists")

        let source = root.appendingPathComponent("unicode.tex"), editor = EditorViewController()
        let firstLease = RealtimeBuildCache(root: root, main: source)
        let concurrentLease = RealtimeBuildCache(root: root, main: source)
        check(firstLease.persistent && !concurrentLease.persistent && firstLease.directory != concurrentLease.directory,
              "concurrent sessions cannot share the engine build directory")
        let temporaryDirectory = concurrentLease.directory
        concurrentLease.release()
        check(!FileManager.default.fileExists(atPath: temporaryDirectory.path), "temporary concurrent-session builds are cleaned up")
        let pass = firstLease.directory.appendingPathComponent("bg/pass-0")
        try FileManager.default.createDirectory(at: pass, withIntermediateDirectories: true)
        try Data("{\"pages\":112}".utf8).write(to: pass.appendingPathComponent("unicode.rtex.json"))
        try Data("hash".utf8).write(to: pass.appendingPathComponent("rtex-sources"))
        firstLease.prepare(main: source)
        check(!FileManager.default.fileExists(atPath: pass.appendingPathComponent("rtex-sources").path),
              "partial or missing PDFs cannot be advertised as a complete startup cache")
        var media = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pdfFile = pass.appendingPathComponent("unicode.pdf")
        let pdfContext = CGContext(pdfFile as CFURL, mediaBox: &media, nil)!
        pdfContext.beginPDFPage(nil); pdfContext.setFillColor(NSColor.white.cgColor); pdfContext.fill(media)
        pdfContext.endPDFPage(); pdfContext.closePDF()
        let goodCapture = Data("{\"pages\":1}".utf8)
        try goodCapture.write(to: pass.appendingPathComponent("unicode.rtex.json"))
        try Data("0123456789abcdef\n".utf8).write(to: pass.appendingPathComponent("rtex-sources"))
        firstLease.preserve(main: source)
        let sealed = firstLease.directory.appendingPathComponent("startup/pass-0")
        check(PDFDocument(url: sealed.appendingPathComponent("unicode.pdf"))?.pageCount == 1,
              "a complete startup pass is sealed outside the mutable engine slots")
        try Data("{\"pages\":1,\"changed\":true}".utf8).write(to: pass.appendingPathComponent("unicode.rtex.json"))
        firstLease.preserve(main: source)
        check((try? Data(contentsOf: sealed.appendingPathComponent("unicode.rtex.json"))) == goodCapture,
              "an old source hash cannot seal a capture from a newer interrupted pass")
        try Data("partial".utf8).write(to: pdfFile)
        firstLease.prepare(main: source)
        check(PDFDocument(url: pdfFile)?.pageCount == 1 && (try? Data(contentsOf: pass.appendingPathComponent("unicode.rtex.json"))) == goodCapture,
              "reopening restores the sealed layout after an interrupted background pass")
        firstLease.release()
        let reopenedLease = RealtimeBuildCache(root: root, main: source)
        check(reopenedLease.persistent && reopenedLease.directory == firstLease.directory,
              "the previous engine cache survives shutdown and is reused")
        reopenedLease.release()
        let composed = "caf\u{e9}\n", decomposed = "cafe\u{301}\n"
        try composed.write(to: source, atomically: true, encoding: .utf8)
        _ = editor.view; try editor.load(source)
        try decomposed.write(to: source, atomically: true, encoding: .utf8)
        check(editor.reloadFromDisk() && editor.textView.string.utf8.elementsEqual(decomposed.utf8), "external Unicode normalization changes reload byte-for-byte")
        var cursorEvents: [(Int, Int)] = []
        editor.onCursorMoved = { cursorEvents.append(($0, $1)) }
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        let caret = editor.caretLineAndColumn()
        check(cursorEvents.count == 1 && cursorEvents.last?.0 == caret.line && cursorEvents.last?.1 == caret.column,
              "mouse/keyboard caret movement is coalesced with a 150 ms follow delay")
        editor.jump(toLine: 999)
        check(editor.textView.selectedRange().location == (decomposed as NSString).length, "out-of-range source navigation clamps to the document end")
        editor.autoCompileDelay = 0.05
        var saveReasons: [EditorViewController.SaveReason] = []
        editor.onSave = { saveReasons.append($0) }
        editor.textView.insertText("automatic", replacementRange: editor.textView.selectedRange())
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        check(saveReasons == [.automatic] && (try? String(contentsOf: source, encoding: .utf8)) == editor.textView.string,
              "autosave reports its reason and still writes the current source")
        check(editor.save() && saveReasons == [.automatic, .explicit], "explicit saves remain distinguishable from autosave")
        let saved = try Data(contentsOf: source)
        editor.textView.insertText("pending", replacementRange: editor.textView.selectedRange())
        editor.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        check((try? Data(contentsOf: source)) == saved && saveReasons == [.automatic, .explicit], "closed editors cannot auto-save pending changes")
        try FileManager.default.removeItem(at: root)
        exit(failures == 0 ? 0 : 1)
    }
}
