import Foundation
import CoreGraphics
import CryptoKit
import TexFastCore

/// Compiles one hovered construct in isolation. Jobs are serial and cancellable;
/// a new hover never starts a second LuaLaTeX process beside the first one.
final class SnippetRenderer {
    private let queue = DispatchQueue(label: "TexFast.snippet-render", qos: .userInitiated)
    private let lock = NSLock()
    private var revision = 0
    private var activeProcess: Process?
    private let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("texfast-hover-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    deinit {
        cancel()
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    func cancel() {
        lock.lock()
        revision += 1
        let process = activeProcess
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    func render(snippet: String, source: String, project: URL,
                completion: @escaping (CGImage?, String?) -> Void) {
        lock.lock()
        revision += 1
        let request = revision
        let previous = activeProcess
        lock.unlock()
        if previous?.isRunning == true { previous?.terminate() }

        queue.async { [weak self] in
            guard let self, self.isCurrent(request) else { return }
            let result = self.compile(snippet: snippet, source: source, project: project, request: request)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(request) else { return }
                completion(result.image, result.message)
            }
        }
    }

    private func isCurrent(_ request: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request == revision
    }

    private func compile(snippet: String, source: String, project: URL,
                         request: Int) -> (image: CGImage?, message: String?) {
        guard let lualatex = Shell.which("lualatex") else {
            return (nil, "LuaLaTeX is needed for snippet previews")
        }
        let preamble: String
        if let begin = source.range(of: #"\\begin\s*\{document\}"#, options: .regularExpression) {
            preamble = String(source[..<begin.lowerBound])
        } else if source.contains(#"\documentclass"#) {
            preamble = source
        } else {
            preamble = #"\documentclass{article}"#
        }

        // Reuse the real preamble so fonts, macros, and package settings match
        // the document. The preview package gives the snippet its own tight page.
        let document = "\\PassOptionsToPackage{active,tightpage}{preview}\n"
            + preamble
            + "\n\\usepackage{preview}\n\\PreviewBorder=6pt\n"
            + "\\begin{document}\n"
            + "\\ifcsname tikzexternaldisable\\endcsname\\tikzexternaldisable\\fi\n"
            + "\\begin{preview}\n" + snippet + "\n\\end{preview}\n\\end{document}\n"
        let key = SHA256.hash(data: Data((project.path + "\0" + document).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = cacheRoot.appendingPathComponent(key, isDirectory: true)
        let input = directory.appendingPathComponent("snippet.tex")
        let pdf = directory.appendingPathComponent("snippet.pdf")
        let log = directory.appendingPathComponent("console.log")

        if let image = Self.image(at: pdf) { return (image, nil) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try document.write(to: input, atomically: true, encoding: .utf8)
        } catch {
            return (nil, "Could not prepare snippet preview")
        }
        try? FileManager.default.removeItem(at: pdf)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: log) else {
            return (nil, "Could not open snippet log")
        }
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lualatex)
        process.arguments = ["-no-shell-escape", "-halt-on-error", "-interaction=nonstopmode",
                             "-output-directory=\(directory.path)", input.path]
        // TeX's own \openout writes stay in this disposable directory. Search
        // the project recursively for inputs and figures without writing there.
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TOOLCHAINS")
        environment["TEXINPUTS"] = "\(project.path)//:" + (environment["TEXINPUTS"] ?? "")
        process.environment = environment

        lock.lock()
        guard request == revision else { lock.unlock(); return (nil, nil) }
        activeProcess = process
        lock.unlock()
        do { try process.run() } catch {
            clear(process)
            return (nil, "Could not start LuaLaTeX")
        }
        if !isCurrent(request), process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        clear(process)
        guard isCurrent(request) else { return (nil, nil) }
        if process.terminationStatus == 0, let image = Self.image(at: pdf) {
            return (image, nil)
        }
        let outputText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let detail = outputText.split(separator: "\n").last { $0.hasPrefix("! ") }
        return (nil, detail.map { String($0.dropFirst(2)) } ?? "Snippet could not render")
    }

    private func clear(_ process: Process) {
        lock.lock()
        if activeProcess === process { activeProcess = nil }
        lock.unlock()
    }

    private static func image(at url: URL) -> CGImage? {
        guard let pdf = CGPDFDocument(url as CFURL), let page = pdf.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0, box.width < 1_000, box.height < 1_000 else { return nil }
        let scale = min(2, 520 / box.width, 360 / box.height)
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
