import Foundation
import TexFastCore

/// Owns one persistent Rust Session through its supported JSON-lines host API.
/// All process I/O, source snapshots and resource loading use a serial queue.
final class RealtimeController {
    let root: URL
    let main: URL
    let buildDirectory: URL
    private let queue = DispatchQueue(label: "texfast.realtime")
    private var process: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var buffer = Data()
    private var documents: [String: String] = [:]
    private var sentFonts = Set<String>()
    private var sentImages = Set<String>()
    private var located: [String: URL] = [:]
    private var fontMap: [String: String]?
    private var spans: [String: [[String: Any]]] = [:]
    private var spanRequests: [String] = []
    private var placements: [[String: Any]] = []
    private var engineFiles = Set<String>()
    private var revision = 1
    private var stopping = false
    private var layoutWork: DispatchWorkItem?
    private var stderrTail = ""
    private var diagnostics: [String: [Problem]] = [:]
    private(set) var available = false
    var onMessage: (([String: Any]) -> Void)?
    var onStatus: ((String, Bool, Bool) -> Void)?
    var onDiagnostics: (([Problem]) -> Void)?
    var onSourceLocation: ((URL, Int) -> Void)?
    var onFailure: ((String) -> Void)?

    init(main: URL) {
        self.main = main
        root = main.deletingLastPathComponent().resolvingSymlinksInPath()
        // Separate per root document and session, so multiple windows cannot race.
        buildDirectory = root.appendingPathComponent(".texfast/realtime/\(main.deletingPathExtension().lastPathComponent)/\(UUID().uuidString)")
    }

    func start() {
        guard let resources = Bundle.main.resourceURL else { return }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rtex")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        available = true
        queue.async { [self] in
            guard !stopping else { return }
            let p = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
            p.executableURL = binary
            p.arguments = ["serve", "--project", root.path, "--main", main.lastPathComponent,
                           "--build", buildDirectory.path]
            p.currentDirectoryURL = root
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            env["RTEX_TEXDIR"] = resources.appendingPathComponent("rtex/tex").path
            env.removeValue(forKey: "TOOLCHAINS")
            p.environment = env
            // Establish snapshots before input commands are enqueued. rtex opens the same
            // on-disk sources; edits afterwards are held only in its in-memory snapshots.
            loadSnapshots()
            engineFiles.insert(main.lastPathComponent)
            p.standardInput = stdin; p.standardOutput = out; p.standardError = err
            process = p; input = stdin.fileHandleForWriting; outputPipe = out; errorPipe = err
            out.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                self?.queue.async { [weak self] in self?.consume(data) }
            }
            err.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(4000))
                }
            }
            p.terminationHandler = { [weak self] p in
                self?.queue.async { [weak self] in
                    guard let self, !stopping else { return }
                    fail("Realtime engine exited (\(p.terminationStatus)): \(stderrTail)")
                }
            }
            do { try p.run(); status("Starting realtime LuaLaTeX…", busy: true) }
            catch { fail("Could not start realtime engine: \(error.localizedDescription)") }
        }
    }

    /// Called on every edit, without waiting for auto-save.
    func update(url: URL, text: String) {
        queue.async { [weak self] in self?.updateBuffer(url: url, text: text) }
    }

    /// On save or external changes, sync disk buffers while protecting the active buffer.
    func refresh(activeURL: URL?, text: String, forceLayout: Bool = false) {
        queue.async { [weak self] in
            guard let self, !stopping else { return }
            let active = activeURL?.resolvingSymlinksInPath()
            sentImages.removeAll()
            let urls = sourceURLs()
            for url in urls where url != active {
                if let value = try? String(contentsOf: url, encoding: .utf8) { updateBuffer(url: url, text: value) }
            }
            if let active { updateBuffer(url: active, text: text) }
            if forceLayout { send(["cmd": "request_layout"]) }
        }
    }

    func reveal(url: URL, line: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let path = relative(url)
            guard let text = documents[path], let candidates = spans[path] else { return }
            let lines = text.components(separatedBy: "\n")
            let byte = lines.prefix(max(0, line - 1)).reduce(0) { $0 + $1.utf8.count + 1 }
            let ordered = candidates.sorted {
                abs((($0["range"] as? [String: Int])?["start"] ?? 0) - byte) < abs((($1["range"] as? [String: Int])?["start"] ?? 0) - byte)
            }
            let containing = candidates.first { span in
                guard let range = span["range"] as? [String: Int] else { return false }
                return byte >= (range["start"] ?? 0) && byte < (range["end"] ?? 0)
            }
            for span in containing.map({ [$0] }) ?? ordered {
                guard let id = span["id"] as? Int,
                      let placement = placements.first(where: { $0["par_id"] as? Int == id }),
                      let fragment = (placement["fragments"] as? [[String: Any]])?.first,
                      let page = fragment["page"] as? Int,
                      let y = (fragment["baselines"] as? [Double])?.first else { continue }
                message(["type": "reveal", "page": page, "x": fragment["x"] ?? 0, "y": y, "force": true])
                return
            }
        }
    }

    func jump(page: Int, x: Double, y: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            var nearest: (Int, Double)?
            for placement in placements {
                guard let id = placement["par_id"] as? Int else { continue }
                for fragment in placement["fragments"] as? [[String: Any]] ?? [] where fragment["page"] as? Int == page {
                    for baseline in fragment["baselines"] as? [Double] ?? [] {
                        let distance = abs(baseline - y) + abs((fragment["x"] as? Double ?? 0) - x) * 0.05
                        if nearest == nil || distance < nearest!.1 { nearest = (id, distance) }
                    }
                }
            }
            guard let id = nearest?.0 else { return }
            for (path, items) in spans {
                guard let span = items.first(where: { $0["id"] as? Int == id }),
                      let start = (span["range"] as? [String: Int])?["start"], let text = documents[path] else { continue }
                let line = text.utf8.prefix(start).filter { $0 == 10 }.count + 1
                let url = root.appendingPathComponent(path)
                DispatchQueue.main.async { [weak self] in self?.onSourceLocation?(url, line) }
                return
            }
        }
    }

    func stop() {
        available = false
        queue.async { [self] in
            guard !stopping else { return }
            stopping = true
            layoutWork?.cancel()
            send(["cmd": "quit"])
            try? input?.close(); input = nil
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            errorPipe?.fileHandleForReading.readabilityHandler = nil
            guard let process else { return }
            queue.asyncAfter(deadline: .now() + 2) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    private func sourceURLs() -> [URL] {
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return items.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "tex" }
            .map { $0.resolvingSymlinksInPath() }.filter { $0.path.hasPrefix(root.path + "/") }
    }

    private func loadSnapshots() {
        for url in sourceURLs() {
            if let text = try? String(contentsOf: url, encoding: .utf8) { documents[relative(url)] = text }
        }
    }

    private func relative(_ url: URL) -> String {
        String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
    }

    private func updateBuffer(url: URL, text: String) {
        guard !stopping, url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { return }
        let path = relative(url)
        if let old = documents[path], old.utf8.elementsEqual(text.utf8) { return }
        if engineFiles.contains(path), let old = documents[path] {
            guard let edit = RealtimeEdit.between(old, text) else { return }
            send(["cmd": "edit", "path": path, "start": edit.start, "end": edit.end, "text": edit.text])
        } else { send(["cmd": "set_document", "path": path, "text": text]) }
        engineFiles.insert(path)
        documents[path] = text
        revision += 1
        spanRequests.append(path)
        send(["cmd": "spans", "path": path])
        status("Realtime · updating layout…", busy: true)
        // Eligible paragraph edits do not automatically request pagination in rtex.
        // Reconcile the whole document once typing pauses, including unsaved buffers.
        layoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !stopping else { return }
            send(["cmd": "request_layout"])
        }
        layoutWork = work
        queue.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let input else { return }
        do { try input.write(contentsOf: data + Data([10])) }
        catch { if !stopping { fail("Realtime input failed: \(error.localizedDescription)") } }
    }

    private func consume(_ data: Data) {
        guard !stopping else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(value)
        }
    }

    private func handle(_ event: [String: Any]) {
        if event["reply"] as? String == "error" {
            // A rejected edit invalidates our snapshots; fall back to the saved PDF build.
            fail("Realtime edit rejected: \(event["message"] as? String ?? "unknown error")")
            return
        }
        if event["reply"] as? String == "spans", !spanRequests.isEmpty {
            let path = spanRequests.removeFirst()
            spans[path] = event["spans"] as? [[String: Any]] ?? []
            if spans[path]?.isEmpty == false { engineFiles.insert(path) }
            return
        }
        guard let kind = event["event"] as? String else { return }
        let versions = event["versions"] as? [String: Any] ?? [:]
        let eventRevision = versions["source_revision"] as? Int ?? revision
        switch kind {
        case "LayoutUpdate":
            let compile = event["compile"] as? [String: Any] ?? [:]
            let convergence = event["convergence"] as? [String: Any] ?? [:]
            let state = convergence["state"] as? String ?? "Stale"
            if compile["state"] as? String == "Failed" {
                message(["type": "banner", "kind": "error", "text": "The realtime compile failed. The preview keeps its last good pages. Check Problems or the LuaLaTeX log."])
                status("Realtime compile failed", busy: false, issues: true)
                return
            }
            placements = event["placements"] as? [[String: Any]] ?? []
            for path in documents.keys.sorted() {
                spanRequests.append(path)
                send(["cmd": "spans", "path": path])
            }
            let pages = event["pages_changed"] as? [[String: Any]] ?? []
            resources(for: pages.compactMap { $0["dl"] as? [String: Any] })
            let version = versions["layout_version"] as? Int ?? 0
            let fallback = (event["pdf_fallback"] as? String).map { URL(fileURLWithPath: $0) }
                ?? buildDirectory.appendingPathComponent("bg/layout-\(version).pdf")
            let pdf = (try? Data(contentsOf: fallback))?.base64EncodedString()
            let keep: Any = eventRevision < revision ? eventRevision + 1 : (state == "Stale" ? (convergence["pending_since"] ?? revision) : NSNull())
            message(["type": "layout", "pages": pages, "pagesTotal": event["pages_total"] ?? 0,
                     "placements": event["placements"] ?? [], "keepFromRevision": keep, "pdf": pdf as Any? ?? NSNull()])
            let held = event["held"] as? [[String: Any]] ?? []
            message(["type": "held", "units": held.map { ["parId": $0["par_id"] ?? 0, "line": $0["line"] ?? NSNull()] }])
            message(["type": "banner", "text": NSNull()])
            let issues = compile["state"] as? String != "Ok" || state == "PassLimitReached"
            let current = eventRevision >= revision && state == "Converged"
            status(current ? "Realtime · layout converged" : "Realtime · \(state.lowercased())", busy: !current && !issues, issues: issues)
        case "ParagraphUpdate":
            let statusValue = event["status"] as? String ?? ""
            if statusValue == "error" { status("Realtime · keeping last good paragraph", busy: true, issues: true); return }
            guard let dl = event["dl"] as? [String: Any] else { return }
            if let id = event["par_id"] as? Int {
                placements.removeAll { $0["par_id"] as? Int == id }
                if statusValue != "removed" { placements.append(["par_id": id, "fragments": event["fragments"] ?? []]) }
            }
            resources(for: [dl])
            message(["type": "paragraph", "parId": event["par_id"] ?? 0, "dl": dl,
                     "native": event["native"] ?? NSNull(), "fragments": statusValue == "removed" ? [] : event["fragments"] ?? [], "revision": eventRevision])
            let timing = event["timing"] as? [String: Any] ?? [:]
            let ms = (timing["total_us"] as? Double ?? 0) / 1000
            status(String(format: "Realtime · %.1f ms · layout pending", ms), busy: true)
        case "Diagnostics":
            let source = event["source"] as? String ?? "engine"
            diagnostics[source] = (event["items"] as? [[String: Any]] ?? []).map { item in
                let file = item["file"] as? String
                let url = file.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : root.appendingPathComponent($0) } ?? main
                return Problem(url: url, line: item["line"] as? Int,
                               severity: (item["severity"] as? String ?? "").lowercased().contains("error") ? 1 : 2,
                               message: item["message"] as? String ?? "", origin: "Realtime")
            }
            let problems = diagnostics.values.flatMap { $0 }
            DispatchQueue.main.async { [weak self] in self?.onDiagnostics?(problems) }
        case "BackgroundScheduled": status("Realtime · background layout scheduled", busy: true)
        default: break
        }
    }

    private func message(_ value: [String: Any]) {
        DispatchQueue.main.async { [weak self] in guard let self, available else { return }; onMessage?(value) }
    }

    private func status(_ text: String, busy: Bool, issues: Bool = false) {
        message(["type": "status", "text": text, "kind": issues ? "warn" : busy ? "live" : "ok", "tooltip": text])
        DispatchQueue.main.async { [weak self] in guard let self, available else { return }; onStatus?(text, busy, issues) }
    }

    private func fail(_ reason: String) {
        guard !stopping else { return }
        stopping = true
        try? input?.close(); input = nil
        if process?.isRunning == true { process?.terminate() }
        DispatchQueue.main.async { [weak self] in self?.available = false; self?.onFailure?(reason) }
    }

    private func locate(_ name: String) -> URL? {
        if let cached = located[name] { return cached }
        let direct = name.hasPrefix("/") ? URL(fileURLWithPath: name) : root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { located[name] = direct; return direct }
        guard let kpse = Shell.which("kpsewhich") else { return nil }
        let result = Shell.run(kpse, [name], cwd: root)
        guard result.status == 0, let path = result.output.split(whereSeparator: \.isNewline).first else { return nil }
        let url = URL(fileURLWithPath: String(path)); located[name] = url; return url
    }

    private func mapLine(_ name: String) -> String? {
        if fontMap == nil {
            fontMap = [:]
            if let url = locate("pdftex.map"), let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    if let key = line.split(whereSeparator: \.isWhitespace).first, !key.hasPrefix("%") { fontMap?[String(key)] = String(line) }
                }
            }
        }
        return fontMap?[name]
    }

    private func fontResource(_ descriptor: [String: Any]) -> [String: Any] {
        let line = mapLine(descriptor["name"] as? String ?? "")
        // Match map-file downloads (<foo.enc, <<font.pfb, <[foo.enc).
        let tokens = line?.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "<[")) } ?? []
        let name = descriptor["filename"] as? String ?? tokens.first(where: { $0.hasSuffix(".pfb") || $0.hasSuffix(".pfa") })
        guard let name, let url = locate(name), let data = try? Data(contentsOf: url) else {
            return ["kind": "missing", "reason": "Font outline unavailable"]
        }
        if ["otf", "ttf"].contains(url.pathExtension.lowercased()) { return ["kind": "sfnt", "data": data.base64EncodedString()] }
        let enc = tokens.first(where: { $0.hasSuffix(".enc") }).flatMap { locate($0) }.flatMap { try? String(contentsOf: $0, encoding: .isoLatin1) }
        return ["kind": "type1", "data": data.base64EncodedString(), "mapLine": line as Any? ?? NSNull(), "encoding": enc as Any? ?? NSNull()]
    }

    private func resources(for lists: [[String: Any]]) {
        var fonts: [[Any]] = [], images: [[Any]] = []
        for dl in lists {
            for descriptor in (dl["fonts"] as? [String: [String: Any]] ?? [:]).values {
                // pgf's nullfont is deliberately invisible and has no outlines.
                guard descriptor["name"] is String || descriptor["filename"] is String || descriptor["psname"] is String || descriptor["fullname"] is String else { continue }
                let filename = descriptor["filename"] as? String
                let key = filename.map { "file:\($0)#\(descriptor["subfont"] as? Int ?? 0)" } ?? "tfm:\(descriptor["name"] ?? descriptor["id"] ?? 0)"
                if sentFonts.insert(key).inserted { fonts.append([key, fontResource(descriptor)]) }
            }
            for info in (dl["images_info"] as? [String: [String: Any]] ?? [:]).values {
                guard let name = info["file"] as? String, info["cached_picture"] as? Bool != true,
                      sentImages.insert(name).inserted else { continue }
                if let url = locate(name), let data = try? Data(contentsOf: url) {
                    let ext = url.pathExtension.lowercased()
                    let mime = ext == "pdf" ? "application/pdf" : ext == "png" ? "image/png" : "image/jpeg"
                    images.append([name, ["kind": ext == "pdf" ? "pdf" : "bitmap", "mime": mime, "data": data.base64EncodedString()]])
                } else { images.append([name, ["kind": "missing", "reason": "Image unavailable"]]) }
            }
        }
        if !fonts.isEmpty || !images.isEmpty { message(["type": "resources", "fonts": fonts, "images": images]) }
    }
}
