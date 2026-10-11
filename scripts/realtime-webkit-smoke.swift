import AppKit
import WebKit
import TexFastCore

// Compile with RealtimeController, RealtimePreviewController and ProblemsViewController.
// Run from a disposable .app containing the release's resources and engine.
@main struct Smoke {
    static func main() throws {
        Shell.ignoreBrokenPipes()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("texfast-wk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let main = root.appendingPathComponent("main.tex")
        let original = "\\documentclass{article}\n\\usepackage[T1]{fontenc}\n\\begin{document}\nHello world. A paragraph to edit live.\n\nSecond paragraph with $x^2$.\n\\end{document}\n"
        try original.write(to: main, atomically: true, encoding: .utf8)
        let engine = RealtimeController(main: main)
        let renderer = RealtimePreviewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let pane = PDFPaneController()
        pane.view.frame = NSRect(x: 0, y: 0, width: 800, height: 900)
        window.contentViewController = pane
        pane.showRealtime(renderer)
        window.setContentSize(NSSize(width: 800, height: 900))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        var gotInitial = false, gotLive = false, gotSettled = false
        var resources = 0
        var finished = false
        func finish(_ code: Int32, _ text: String) {
            guard !finished else { return }; finished = true
            print(text)
            engine.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                try? FileManager.default.removeItem(at: root)
                exit(code)
            }
        }
        engine.onFailure = { finish(1, "FAIL engine: \($0)") }
        renderer.onFailure = { finish(1, "FAIL renderer: \($0)") }
        engine.onMessage = { message in
            renderer.post(message)
            if message["type"] as? String == "resources" {
                resources += 1
                for font in message["fonts"] as? [[Any]] ?? [] {
                    if let resource = font.last as? [String: Any], resource["kind"] as? String == "missing" {
                        finish(1, "FAIL missing font: \(font)")
                    }
                }
            }
            if message["type"] as? String == "paragraph" {
                gotLive = true
                print("Received live paragraph")
            }
        }
        engine.onStatus = { text, busy, issues in
            print(text)
            if issues { finish(1, "FAIL: \(text)"); return }
            guard !busy else { return }
            if !gotInitial {
                gotInitial = true
                engine.update(url: main, text: original.replacingOccurrences(of: "world", with: "realtime"))
                return
            }
            guard gotLive, !gotSettled else { return }
            gotSettled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let web = renderer.view as? WKWebView else { finish(1, "No webview"); return }
                web.evaluateJavaScript("JSON.stringify({ canvases: document.querySelectorAll('canvas').length, pages: document.getElementById('pageNo')?.textContent, text: document.body.innerText, width: document.querySelector('canvas')?.width, image: document.querySelector('canvas')?.toDataURL('image/png'), pixels: Array.from(document.querySelectorAll('canvas')).reduce((n,c) => n + Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data).filter((v,i,a) => i%4===0 && v<100 && a[i+3]===255).length, 0) })") { value, error in
                    guard error == nil, let json = value as? String,
                          let data = json.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (result["canvases"] as? Int ?? 0) > 0, (result["width"] as? Int ?? 0) > 300, (result["pixels"] as? Int ?? 0) > 100,
                          resources > 0, (try? String(contentsOf: main, encoding: .utf8)) == original else {
                        finish(1, "FAIL canvas: opaque painted page missing; \(String(describing: error))"); return
                    }
                    guard let encoded = result["image"] as? String,
                          let png = Data(base64Encoded: String(encoded.split(separator: ",", maxSplits: 1).last ?? "")) else {
                        finish(1, "FAIL: canvas screenshot missing"); return
                    }
                    do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
                    catch { finish(1, "FAIL screenshot: \(error)"); return }
                    finish(0, "PASS WKWebView: initial layout, font resources, live edit, convergence, canvas pixels, source unchanged; screenshot saved")
                }
            }
        }
        engine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { finish(1, "FAIL: timed out") }
        app.run()
    }
}
