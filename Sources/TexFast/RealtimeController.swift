import Foundation
import TexFastCore

/// Owns one persistent Rust Session through its supported JSON-lines host API.
/// Process I/O, source snapshots and complete PDF snapshots use a serial queue.
final class RealtimeController {
    let root: URL
    let main: URL
    private var buildCache: RealtimeBuildCache?
    private(set) var buildDirectory: URL
    private let queue = DispatchQueue(label: "texfast.realtime")
    private var process: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var framer = JSONLineFramer()
    private var documents: [String: String] = [:]
    private var spans: [String: [[String: Any]]] = [:]
    private struct SpanRequest { let path: String; let revision: Int; let finished: (() -> Void)? }
    private var spanRequests: [SpanRequest] = []
    private var documentRevisions: [String: Int] = [:]
    private var navigationSequence = 0
    private var placements: [[String: Any]] = []
    private var committedPlacements: [[String: Any]] = []
    private var pagePlacements: [[String: Any]] = []
    private var layoutVersion = 0
    private var previewRun = 0
    private var discardedPreviewRun = 0
    private var previewRevisions: [Int: Int] = [:]
    private var placementRevisions: [Int: Int] = [:]
    private var engineFiles = Set<String>()
    private var revision = 1
    private var publishedRevision = 0
    private var liveEvents: [Int: [String: Any]] = [:]
    private lazy var liveRenderer = NativeLiveRenderer(root: root)
    private var stopping = false
    private var stderrTail = ""
    private var diagnostics: [String: [Problem]] = [:]
    private let availabilityLock = NSLock()
    private var isAvailable = false
    private(set) var available: Bool {
        get { availabilityLock.lock(); defer { availabilityLock.unlock() }; return isAvailable }
        set { availabilityLock.lock(); defer { availabilityLock.unlock() }; isAvailable = newValue }
    }
    var onFast: ((NativeLiveUnit) -> Void)?
    var onPagePreview: ((NativeLivePagePreview, [NativeLiveUnit]) -> Void)?
    var onPagePreviewReset: (([NativeLiveUnit]) -> Void)?
    var onPDF: ((Data, Int, Int) -> Void)?
    var onReveal: ((PDFLocation, Bool) -> Void)?
    var onStatus: ((String, Bool, Bool) -> Void)?
    var onDiagnostics: (([Problem]) -> Void)?
    var onSourceLocation: ((URL, Int) -> Void)?
    var onFailure: ((String) -> Void)?
    var onEngineState: ((String) -> Void)?

    init(main: URL) {
        self.main = main
        root = main.deletingLastPathComponent().resolvingSymlinksInPath()
        // Separate per root document and session, so multiple windows cannot race.
        buildDirectory = root.appendingPathComponent(".texfast/realtime/\(main.deletingPathExtension().lastPathComponent)/\(UUID().uuidString)")
    }

    func start() {
        guard let resources = Bundle.main.resourceURL else { return }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rtex-host")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        available = true
        queue.async { [self] in
            guard !stopping else { return }
            let cache = RealtimeBuildCache(root: root, main: main)
            cache.prepare(main: main)
            buildCache = cache; buildDirectory = cache.directory
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
            p.terminationHandler = { [weak self, cache] p in
                guard let self else {
                    cache.release()
                    return
                }
                self.queue.async { [self] in
                    self.releaseSessionFiles()
                    guard !self.stopping else { return }
                    self.fail("Realtime engine exited (\(p.terminationStatus)): \(self.stderrTail)")
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
            let urls = sourceURLs()
            if let removed = documents.keys.sorted().first(where: {
                let url = self.root.appendingPathComponent($0)
                return url != active && !FileManager.default.fileExists(atPath: url.path)
            }) {
                // The serve protocol has no remove-document API and otherwise keeps deleted text.
                fail("Source removed: \(removed). Rebuilding from the project on disk.")
                return
            }
            for url in urls where url != active {
                if let value = try? String(contentsOf: url, encoding: .utf8) { updateBuffer(url: url, text: value) }
            }
            if let active { updateBuffer(url: active, text: text) }
            if forceLayout { send(["cmd": "request_layout"]) }
        }
    }

    /// Settle the engine's current unsaved snapshots without re-reading disk.
    func requestLayout() {
        queue.async { [weak self] in
            guard let self, !stopping else { return }
            send(["cmd": "request_layout"])
        }
    }

    func reveal(url: URL, line: Int, column: Int = 1, force: Bool = true) {
        queue.async { [weak self] in
            guard let self, !stopping else { return }
            navigationSequence += 1
            resolveCursor(path: relative(url), line: line, column: column, force: force, token: navigationSequence)
        }
    }

    private func requestSpans(_ path: String, finished: (() -> Void)? = nil) {
        spanRequests.append(SpanRequest(path: path, revision: documentRevisions[path] ?? 1, finished: finished))
        send(["cmd": "spans", "path": path])
    }

    private func resolveCursor(path: String, line: Int, column: Int, force: Bool, token: Int) {
        guard !stopping, token == navigationSequence, !placements.isEmpty, let text = documents[path] else { return }
        guard let candidates = spans[path] else {
            requestSpans(path) { [weak self] in
                self?.resolveCursor(path: path, line: line, column: column, force: force, token: token)
            }
            return
        }
        let byte = RealtimeSourceMap.byteOffset(text: text, line: line, column: column)
        guard let target = RealtimeSourceMap.target(byte: byte, spans: candidates, placements: placements) else { return }
        let location = PDFLocation(page: target.page, x: target.x / 65781.76, y: target.y / 65781.76, width: 24, height: 12)
        DispatchQueue.main.async { [weak self] in
            guard let self, available else { return }
            onReveal?(location, force)
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
        let edit = documents[path].flatMap { RealtimeEdit.between($0, text) }
        if documents[path] != nil && edit == nil { return }
        if engineFiles.contains(path), let edit {
            send(["cmd": "edit", "path": path, "start": edit.start, "end": edit.end, "text": edit.text])
        } else { send(["cmd": "set_document", "path": path, "text": text]) }
        engineFiles.insert(path)
        documents[path] = text
        revision += 1
        documentRevisions[path] = revision
        spans.removeValue(forKey: path)
        status("Realtime · updating live drawing…", busy: false)
        // The engine schedules reflow for row-count, structural and reference
        // changes itself. Do not turn every keystroke into a full-PDF request.
    }

    private func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let input else { return }
        do { try input.write(contentsOf: data + Data([10])) }
        catch { if !stopping { fail("Realtime input failed: \(error.localizedDescription)") } }
    }

    private func consume(_ data: Data) {
        guard !stopping else { return }
        for line in framer.append(data) {
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
            let request = spanRequests.removeFirst()
            if request.revision == (documentRevisions[request.path] ?? 1) {
                spans[request.path] = event["spans"] as? [[String: Any]] ?? []
                if spans[request.path]?.isEmpty == false { engineFiles.insert(request.path) }
            }
            request.finished?()
            return
        }
        guard let kind = event["event"] as? String else { return }
        let versions = event["versions"] as? [String: Any] ?? [:]
        let eventRevision = versions["source_revision"] as? Int ?? revision
        switch kind {
        case "EngineState":
            let engineState = event["state"] as? String ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self, available else { return }
                onEngineState?(engineState)
            }
            switch event["state"] as? String {
            case "Ready":
                if publishedRevision == 0 { status("Realtime engine ready · preparing document layout…", busy: true) }
            case "Failed":
                fail("Realtime engine startup failed: \(event["reason"] as? String ?? "unknown error")")
            default: break
            }
        case "PagePreview":
            guard event["base_layout_version"] as? Int == layoutVersion,
                  let run = event["run_id"] as? Int, run >= previewRun, run > discardedPreviewRun,
                  let sourceRevision = event["source_revision"] as? Int, sourceRevision >= publishedRevision,
                  let page = event["page"] as? [String: Any], let n = page["page"] as? Int,
                  sourceRevision >= (previewRevisions[n] ?? 0),
                  let prepared = liveRenderer.preparePagePreview(event) else { return }
            previewRun = run
            let incoming = event["placements"] as? [[String: Any]] ?? []
            let candidate = RealtimeSourceMap.mergePage(n, incoming: incoming, into: pagePlacements)
            // An old snapshot must never hide a newer growing paragraph. Keep the
            // immediate live drawing until a compatible page catches up instead.
            guard !liveEvents.values.contains(where: { conflictsWithPreview($0, placements: candidate, revisions: [n: sourceRevision]) }) else { return }
            pagePlacements = candidate
            liveRenderer.installPagePreview(page, placements: incoming)
            previewRevisions[n] = sourceRevision
            let current = rebuildLiveUnits()
            DispatchQueue.main.async { [weak self] in
                guard let self, available else { return }
                onPagePreview?(prepared, current)
            }
            status("Live · page \(n) reflowed · document still typesetting", busy: false)
        case "PagePreviewReset":
            guard event["base_layout_version"] as? Int == layoutVersion,
                  let run = event["run_id"] as? Int, run >= previewRun else { return }
            discardedPreviewRun = max(discardedPreviewRun, run)
            restorePagePreviews()
            let current = rebuildLiveUnits()
            DispatchQueue.main.async { [weak self] in
                guard let self, available else { return }
                onPagePreviewReset?(current)
            }
        case "LayoutUpdate":
            let compile = event["compile"] as? [String: Any] ?? [:]
            let convergence = event["convergence"] as? [String: Any] ?? [:]
            let state = convergence["state"] as? String ?? "Stale"
            liveRenderer.recordLayoutPages(event)
            // Like the plugin, advance pagination during typing while retaining
            // every live result newer than the source snapshot used by the pass.
            let capturedRevision = state == "Stale"
                ? max(0, (convergence["pending_since"] as? Int ?? 1) - 1) : eventRevision
            guard capturedRevision >= publishedRevision else { return }
            if compile["state"] as? String == "Failed" {
                status("Realtime compile failed · keeping the last good PDF", busy: false, issues: true)
                return
            }
            committedPlacements = event["placements"] as? [[String: Any]] ?? []
            pagePlacements = committedPlacements
            placements = committedPlacements
            placementRevisions.removeAll()
            for path in documents.keys.sorted() {
                requestSpans(path)
            }
            let version = versions["layout_version"] as? Int ?? 0
            let pdfURL = (event["pdf_fallback"] as? String).map { URL(fileURLWithPath: $0) }
                ?? buildDirectory.appendingPathComponent("bg/layout-\(version).pdf")
            // Copy the complete stable PDF now: rtex eventually prunes older layout files.
            guard let data = try? Data(contentsOf: pdfURL), !data.isEmpty else {
                status("Realtime PDF unavailable · keeping the last good preview", busy: false, issues: true)
                return
            }
            liveRenderer.resetPagePreviews()
            previewRevisions.removeAll(); previewRun = 0; discardedPreviewRun = 0
            layoutVersion = version
            liveRenderer.installLayout(event)
            if state == "Converged" { buildCache?.preserve(main: main) }
            publishedRevision = capturedRevision
            liveEvents = liveEvents.filter { (($0.value["versions"] as? [String: Any])?["source_revision"] as? Int ?? 0) > capturedRevision }
            let rebased = rebuildLiveUnits()
            DispatchQueue.main.async { [weak self] in
                guard let self, available else { return }
                onPDF?(data, capturedRevision, version)
                for unit in rebased { onFast?(unit) }
            }
            let issues = compile["state"] as? String != "Ok" || state == "PassLimitReached"
            let current = eventRevision >= revision && state == "Converged"
            status(current ? "Realtime · layout converged" : !rebased.isEmpty ? "Live · pagination catching up" : "Realtime · \(state.lowercased())",
                   busy: !current && !issues && rebased.isEmpty, issues: issues)
        case "ParagraphUpdate":
            guard eventRevision > publishedRevision else { return }
            let statusValue = event["status"] as? String ?? ""
            if statusValue == "error" {
                if eventRevision >= revision { status("Realtime · source has errors · keeping the last good PDF", busy: true, issues: true) }
                return
            }
            if let id = event["par_id"] as? Int {
                let previous = (liveEvents[id]?["versions"] as? [String: Any])?["source_revision"] as? Int ?? 0
                guard eventRevision >= previous else { return }
            }
            if conflictsWithPreview(event, placements: pagePlacements, revisions: previewRevisions),
               liveRenderer.prepare(event) != nil {
                // Row growth needs new pagination. Restore the base and continue
                // live drawing; the engine is already arranging the next page.
                if let id = event["par_id"] as? Int { liveEvents[id] = event }
                restorePagePreviews()
                let current = rebuildLiveUnits()
                DispatchQueue.main.async { [weak self] in
                    guard let self, available else { return }
                    onPagePreviewReset?(current)
                }
            }
            // A newer global revision may edit a different unit. The overlay orders
            // each unit independently and rejects updates older than its committed PDF.
            guard let (unit, located) = prepareLive(event) else {
                if (event["fragments"] as? [[String: Any]])?.isEmpty == true, let id = event["par_id"] as? Int {
                    // v0.0.10 retains an off-page live box until a page supplies anchors.
                    liveEvents[id] = event
                    status("Realtime · live box ready · page placement pending", busy: true)
                } else if eventRevision >= revision {
                    status("Realtime · this unit needs the full layout; live drawing unavailable", busy: true)
                }
                return
            }
            liveEvents[unit.id] = event
            updatePlacement(id: unit.id, event: located, revision: eventRevision)
            DispatchQueue.main.async { [weak self] in
                guard let self, available else { return }
                onFast?(unit)
            }
            let timing = event["timing"] as? [String: Any] ?? [:]
            let ms = (timing["total_us"] as? Double ?? 0) / 1000
            if eventRevision >= revision {
                status(unit.pages.isEmpty ? "Live · page reflow catching up" : String(format: "Live · paragraph %.1f ms · pagination pending", ms), busy: false)
            }
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
            DispatchQueue.main.async { [weak self] in guard let self, available else { return }; onDiagnostics?(problems) }
        case "BackgroundScheduled":
            if publishedRevision < revision {
                let live = liveEvents.values.contains { (($0["versions"] as? [String: Any])?["source_revision"] as? Int ?? 0) == revision }
                status(live ? "Live · pagination catching up" : "Realtime · background layout scheduled", busy: !live)
            }
        default: break
        }
    }

    private func conflictsWithPreview(_ event: [String: Any], placements: [[String: Any]], revisions: [Int: Int]) -> Bool {
        guard let id = event["par_id"] as? Int,
              let revision = (event["versions"] as? [String: Any])?["source_revision"] as? Int else { return false }
        let rows = (event["dl"] as? [String: Any])?["lines"] as? [[String: Any]] ?? []
        let placed = placements.first { $0["par_id"] as? Int == id }?["fragments"] as? [[String: Any]] ?? []
        let representedRows = placed.map { $0["last_line"] as? Int ?? 0 }.max() ?? 0
        let fragments = placed + (event["fragments"] as? [[String: Any]] ?? [])
        return representedRows != rows.count && fragments.contains { fragment in
            guard let page = fragment["page"] as? Int, let captured = revisions[page] else { return false }
            return revision > captured
        }
    }

    private func restorePagePreviews() {
        liveRenderer.resetPagePreviews()
        previewRevisions.removeAll()
        pagePlacements = committedPlacements
    }

    private func rebuildLiveUnits() -> [NativeLiveUnit] {
        placements = pagePlacements
        placementRevisions.removeAll()
        var current: [NativeLiveUnit] = []
        for id in liveEvents.keys.sorted() {
            guard let event = liveEvents[id], let (unit, located) = prepareLive(event, reanchor: true) else { continue }
            current.append(unit)
            updatePlacement(id: id, event: located, revision: unit.revision)
        }
        return current
    }

    private func prepareLive(_ event: [String: Any], reanchor: Bool = false) -> (NativeLiveUnit, [String: Any])? {
        var located = event
        let place = pagePlacements.first { $0["par_id"] as? Int == event["par_id"] as? Int }
        let rows = (event["dl"] as? [String: Any])?["lines"] as? [[String: Any]] ?? []
        if (reanchor || !previewRevisions.isEmpty), event["status"] as? String != "removed",
           let fragments = place?["fragments"] as? [[String: Any]], !fragments.isEmpty, !rows.isEmpty {
            located["fragments"] = RealtimeSourceMap.reanchor(placements: fragments, rows: rows)
        }
        guard let unit = liveRenderer.prepare(located) else { return nil }
        let fragments = place?["fragments"] as? [[String: Any]] ?? []
        let capturedRows = fragments.map { $0["last_line"] as? Int ?? 0 }.max() ?? 0
        let visible = unit.pages.filter { page, _ in
            guard let captured = previewRevisions[page] else { return true }
            return unit.revision > captured && capturedRows == rows.count
        }
        if !previewRevisions.isEmpty, event["status"] as? String != "removed" {
            // Follow the coherent page where a newer box has not caught up in height.
            let live = (located["fragments"] as? [[String: Any]] ?? []).filter { visible[$0["page"] as? Int ?? 0] != nil }
            let covered = fragments.filter { visible[$0["page"] as? Int ?? 0] == nil }
            located["fragments"] = (live + covered).sorted { ($0["page"] as? Int ?? 0) < ($1["page"] as? Int ?? 0) }
        }
        return (NativeLiveUnit(id: unit.id, revision: unit.revision, pages: visible), located)
    }

    private func updatePlacement(id: Int, event: [String: Any], revision: Int) {
        guard revision >= (placementRevisions[id] ?? publishedRevision) else { return }
        placementRevisions[id] = revision
        if event["status"] as? String == "removed" {
            placements.removeAll { $0["par_id"] as? Int == id }
        } else if let fragments = event["fragments"] as? [[String: Any]] {
            if let index = placements.firstIndex(where: { $0["par_id"] as? Int == id }) {
                placements[index]["fragments"] = fragments
            } else {
                placements.append(["par_id": id, "fragments": fragments])
            }
        }
    }

    private func status(_ text: String, busy: Bool, issues: Bool = false) {
        DispatchQueue.main.async { [weak self] in guard let self, available else { return }; onStatus?(text, busy, issues) }
    }

    private func releaseSessionFiles() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        outputPipe = nil; errorPipe = nil
        buildCache?.release(); buildCache = nil
    }

    private func fail(_ reason: String) {
        guard !stopping else { return }
        stopping = true
        available = false
        try? input?.close(); input = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        else { releaseSessionFiles() }
        DispatchQueue.main.async { [weak self] in self?.available = false; self?.onFailure?(reason) }
    }

}
