import Foundation

public struct BuildReport {
    public var figuresBuilt = 0
    public var figuresFailed: [String] = []
    public var figuresCached = 0
    public var imagesConverted = 0
    public var imagesLinked = 0
    public var passes = 0
    public var pdf: URL?
    /// Set when the build could not finish. The CLI exits on it; the app shows it.
    public var error: String?
    public var texSeconds = 0.0
    public var figureSeconds = 0.0
    public var pdfSeconds = 0.0
    public var totalSeconds = 0.0
}

public struct Driver {
    public let texFile: URL
    public let projectDir: URL
    public let cacheDir: URL
    public var draft: Bool
    public var jobs: Int

    public init(texFile: URL, projectDir: URL, cacheDir: URL, draft: Bool, jobs: Int) {
        self.texFile = texFile
        self.projectDir = projectDir
        self.cacheDir = cacheDir
        self.draft = draft
        self.jobs = jobs
    }

    /// Where a draft build leaves its PDF.
    public var draftPDF: URL { buildDir.appendingPathComponent(jobName + ".pdf") }
    /// The shadow copy that is actually compiled; SyncTeX reports positions in it.
    public var shadowFile: URL { buildDir.appendingPathComponent(jobName + ".tex") }
    public var synctexFile: URL { buildDir.appendingPathComponent(jobName + ".synctex.gz") }

    public var buildDir: URL { cacheDir.appendingPathComponent("build") }
    var figDir: URL { buildDir.appendingPathComponent("figs") }
    var imgDir: URL { cacheDir.appendingPathComponent("img") }
    var blocklistFile: URL { cacheDir.appendingPathComponent("blocked-figures.txt") }
    /// stderr is invisible when the app is launched from Finder, so every build
    /// leaves its output here.
    public var buildLog: URL { cacheDir.appendingPathComponent("build.log") }
    var jobName: String { texFile.deletingPathExtension().lastPathComponent }

    private var xelatex: String? { Shell.which("xelatex") }
    private var xdvipdfmx: String? { Shell.which("xdvipdfmx") }

    // MARK: - entry points

    public func build(figuresOnly: Bool) -> BuildReport {
        let started = Date()
        var report = BuildReport()

        try? FileManager.default.createDirectory(at: figDir, withIntermediateDirectories: true)
        // Two builds sharing one build directory corrupt each other's .xdv —
        // the app and a `fastex` run in a terminal, say. Serialise them.
        let lock = BuildLock(cacheDir.appendingPathComponent("build.lock"))
        lock.acquire()
        defer { lock.release() }
        try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)

        guard let xelatex, let xdvipdfmx else {
            report.error = "xelatex/xdvipdfmx not found on PATH"
            return report
        }
        guard let source = try? String(contentsOf: texFile, encoding: .utf8) else {
            report.error = "cannot read \(texFile.path)"
            return report
        }
        let scan = TeXScanner.scan(source)
        if scan.beginDocument < 0 {
            report.error = "no \\begin{document} in \(texFile.lastPathComponent)"
            return report
        }

        linkProjectFiles()

        // 1. images
        var rewrites: [Int: String] = [:]
        if draft {
            let cache = ImageCache(dir: imgDir)
            var resolvedCache: [String: String?] = [:]
            var linked = 0
            for (idx, img) in scan.images.enumerated() {
                if let memo = resolvedCache[img.name] {
                    if let name = memo { rewrites[idx] = "../img/" + name; linked += 1 }
                    continue
                }
                var produced: String? = nil
                if let original = ImageCache.resolve(img.name, in: projectDir),
                   let hit = cache.cachedName(for: original) {
                    produced = hit.name
                    rewrites[idx] = "../img/" + hit.name
                    if hit.converted { report.imagesConverted += 1 }
                    linked += 1
                }
                resolvedCache[img.name] = produced
            }
            report.imagesLinked = linked
        }

        // 2. shadow source
        var blocked = loadBlocklist()
        writeShadow(scan, rewrites: rewrites, blocked: blocked)

        // 3. figures. Names are content-addressed, so the set of jobs is known
        //    without asking TeX for a figure list first.
        let figStart = Date()
        var missing = draft ? scan.pictures : []
        missing = missing
            .filter { !blocked.contains($0.key) }
            .filter { !FileManager.default.fileExists(atPath: figPDF($0.key).path) }
        // A picture repeated verbatim hashes the same; build it once.
        missing = dedupe(missing)
        report.figuresCached = draft ? (scan.pictures.count - missing.count - blocked.count) : 0

        if !missing.isEmpty {
            log("fastex: building \(missing.count) figure(s) on \(jobs) cores…")
            let failures = buildFigures(missing.map { $0.key }, xelatex: xelatex)
            report.figuresBuilt = missing.count - failures.count
            report.figuresFailed = failures
            var fallbacks = Set(failures)
            fallbacks.formUnion(definersOfMissingShapes(failedKeys: failures, scan: scan))
            if !fallbacks.isEmpty {
                // A figure that cannot be externalised is compiled inline instead
                // of being silently dropped from the document.
                blocked.formUnion(fallbacks)
                saveBlocklist(blocked)
                writeShadow(scan, rewrites: rewrites, blocked: blocked)
                log("fastex: \(fallbacks.count) figure(s) fell back to inline compilation")
            }
        }
        report.figureSeconds = Date().timeIntervalSince(figStart)

        if figuresOnly {
            report.totalSeconds = Date().timeIntervalSince(started)
            return report
        }

        // 4. TeX passes, reruns only when cross-references actually moved.
        var fingerprint = auxFingerprint()
        for pass in 1...2 {
            let r = runTeX(xelatex)
            report.texSeconds += r.duration
            report.passes = pass
            if r.status != 0 && !FileManager.default.fileExists(atPath: xdvPath().path) {
                appendLog(r.output)
                report.error = lastErrors(from: r.output).isEmpty
                    ? "xelatex failed — see \(buildDir.appendingPathComponent(jobName + ".log").path)"
                    : lastErrors(from: r.output)
                return report
            }
            let after = auxFingerprint()
            if after == fingerprint { break }
            fingerprint = after
            if pass == 1 { log("fastex: cross-references moved, running pass 2") }
        }

        // 5. xdv -> pdf
        var pdfRun = Shell.run(xdvipdfmx, ["-q", "-o", jobName + ".pdf", jobName + ".xdv"], cwd: buildDir)
        if pdfRun.status != 0 {
            // A build killed part-way leaves a truncated .xdv, and every later
            // build then fails on it. Regenerate it once before giving up.
            appendLog("xdvipdfmx failed, regenerating the .xdv and retrying:\n" + pdfRun.output)
            try? FileManager.default.removeItem(at: xdvPath())
            let retry = runTeX(xelatex)
            report.texSeconds += retry.duration
            pdfRun = Shell.run(xdvipdfmx, ["-q", "-o", jobName + ".pdf", jobName + ".xdv"], cwd: buildDir)
        }
        report.pdfSeconds = pdfRun.duration
        if pdfRun.status != 0 {
            appendLog(pdfRun.output)
            report.error = "xdvipdfmx failed — see \(buildLog.path)"
            return report
        }

        var out = buildDir.appendingPathComponent(jobName + ".pdf")
        if !draft {
            // Only a lossless build is allowed to land next to the source.
            let final = projectDir.appendingPathComponent(jobName + ".pdf")
            try? FileManager.default.removeItem(at: final)
            try? FileManager.default.copyItem(at: out, to: final)
            out = final
        }
        report.pdf = out
        report.totalSeconds = Date().timeIntervalSince(started)
        return report
    }

    // MARK: - steps

    private func writeShadow(_ scan: ScanResult, rewrites: [Int: String], blocked: Set<String>) {
        // A final build externalizes nothing: an externalized figure carries a
        // tight bounding box, which nudges the spacing of side-by-side figures
        // by a fraction of a point. Invisible in a draft, but the handed-in PDF
        // should match a stock xelatex run exactly.
        let opts = ShadowSource.Options(externalize: draft,
                                        figPrefix: "figs/",
                                        imageRewrites: rewrites,
                                        blockedKeys: blocked)
        let text = ShadowSource.render(scan, options: opts)
        try? text.write(to: shadowTeX(), atomically: true, encoding: .utf8)
    }

    private func runTeX(_ xelatex: String) -> RunResult {
        Shell.run(xelatex,
                  ["-shell-escape", "-no-pdf", "-synctex=1",
                   "-interaction=nonstopmode", "-file-line-error", jobName + ".tex"],
                  cwd: buildDir,
                  env: ["TEXINPUTS": ".:\(projectDir.path):"])
    }

    /// Compile each missing picture in its own process. This is exactly what
    /// tikz's own `main.makefile` does, minus the makefile — which also sidesteps
    /// the library's habit of emitting literal `^^I` instead of tabs.
    private func buildFigures(_ keys: [String], xelatex: String) -> [String] {
        let lock = NSLock()
        var failures: [String] = []
        let sem = DispatchSemaphore(value: max(1, jobs))
        let group = DispatchGroup()

        for key in keys {
            sem.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { sem.signal(); group.leave() }
                _ = Shell.run(xelatex,
                              ["-shell-escape", "-interaction=nonstopmode",
                               "-jobname", "figs/f\(key)",
                               "\\def\\tikzexternalrealjob{\(jobName)}\\input{\(jobName)}"],
                              cwd: buildDir,
                              env: ["TEXINPUTS": ".:\(projectDir.path):"])
                // Judge purely on the artifact: nonstopmode keeps going past errors
                // raised by other pictures, which say nothing about this one.
                let ok = FileManager.default.fileExists(atPath: figPDF(key).path)
                if !ok {
                    lock.lock(); failures.append(key); lock.unlock()
                }
            }
        }
        group.wait()
        return failures
    }

    /// Symlink the project's assets next to the shadow file so relative
    /// references (images, \input files, .bib) resolve without touching the source.
    private func linkProjectFiles() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: projectDir.path) else { return }
        // Anything the build itself writes must never be symlinked in, or the
        // compiler writes straight through the link and destroys the original.
        let generated: Set<String> = ["pdf", "log", "aux", "toc", "out", "xdv", "dvi",
                                      "fls", "fdb_latexmk", "synctex", "gz", "figlist",
                                      "makefile", "bbl", "blg", "idx", "ind", "lof", "lot"]
        for name in entries where !name.hasPrefix(".") {
            if name == texFile.lastPathComponent { continue }
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension.lowercased()
            // Guard the job's own artefacts by name, and every build extension by kind.
            if stem == jobName || stem.hasPrefix(jobName + ".") { continue }
            if generated.contains(ext) { continue }
            let src = projectDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let dst = buildDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) || (try? fm.destinationOfSymbolicLink(atPath: dst.path)) != nil { continue }
            try? fm.createSymbolicLink(at: dst, withDestinationURL: src)
        }
    }


    /// A picture that references a node from another picture cannot be
    /// externalized — and neither can the picture that *defines* that node, or
    /// the inline fallback would still find nothing. pgfplots reports this as
    /// "No shape named `axis1' is known", so read the name back out of the log
    /// and block whichever picture declares it.
    private func definersOfMissingShapes(failedKeys: [String], scan: ScanResult) -> Set<String> {
        var shapes = Set<String>()
        for key in failedKeys {
            let logURL = figDir.appendingPathComponent("f\(key).log")
            guard let text = try? String(contentsOf: logURL, encoding: .isoLatin1) else { continue }
            var rest = Substring(text)
            while let hit = rest.range(of: "No shape named `") {
                rest = rest[hit.upperBound...]
                if let close = rest.firstIndex(of: "'") {
                    shapes.insert(String(rest[rest.startIndex..<close]))
                    rest = rest[close...]
                }
            }
        }
        guard !shapes.isEmpty else { return [] }

        var extra = Set<String>()
        for pic in scan.pictures where !failedKeys.contains(pic.key) {
            let body = String(scan.chars[pic.start..<pic.end])
            for shape in shapes where body.contains("name=\(shape)") || body.contains("name = \(shape)") {
                extra.insert(pic.key)
            }
        }
        if !extra.isEmpty {
            log("fastex: \(extra.count) picture(s) also kept inline — they define nodes used across pictures")
        }
        return extra
    }

    // MARK: - small helpers

    private func dedupe(_ pictures: [Picture]) -> [Picture] {
        var seen = Set<String>()
        return pictures.filter { seen.insert($0.key).inserted }
    }

    private func shadowTeX() -> URL { buildDir.appendingPathComponent(jobName + ".tex") }
    private func xdvPath() -> URL { buildDir.appendingPathComponent(jobName + ".xdv") }
    private func figPDF(_ key: String) -> URL { figDir.appendingPathComponent("f\(key).pdf") }

    private func auxFingerprint() -> String {
        var parts: [String] = []
        for ext in ["aux", "toc", "out"] {
            let u = buildDir.appendingPathComponent(jobName + "." + ext)
            if let d = try? Data(contentsOf: u) { parts.append(TeXScanner.md5Hex(d)) } else { parts.append("-") }
        }
        return parts.joined(separator: ":")
    }

    private func loadBlocklist() -> Set<String> {
        guard let text = try? String(contentsOf: blocklistFile, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map(String.init))
    }

    private func saveBlocklist(_ set: Set<String>) {
        try? set.sorted().joined(separator: "\n").write(to: blocklistFile, atomically: true, encoding: .utf8)
    }

    private func appendLog(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\n===== \(stamp) =====\n" + text
        if let handle = try? FileHandle(forWritingTo: buildLog) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: buildLog, atomically: true, encoding: .utf8)
        }
    }

    private func lastErrors(from output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let errors = lines.filter { $0.contains(":") && ($0.contains("Error") || $0.hasPrefix("!")) }
        return errors.suffix(2).joined(separator: " · ")
    }
}


/// Advisory whole-build lock, so concurrent `fastex` processes queue instead of
/// writing over one another.
final class BuildLock {
    private var fd: Int32 = -1
    private let url: URL

    init(_ url: URL) { self.url = url }

    func acquire() {
        fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            log("fastex: another build is running here, waiting…")
            _ = flock(fd, LOCK_EX)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
