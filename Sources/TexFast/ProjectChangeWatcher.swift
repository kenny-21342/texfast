import Foundation

/// Watches project inputs on a background queue. Directory mtimes alone miss
/// edits inside existing chapter and image files, while a vnode watch loses
/// atomic replacements. Polling only file metadata keeps the main thread free.
final class ProjectChangeWatcher {
    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private let projectURL: URL
    private let rootPDF: URL
    private let onChange: ([URL]) -> Void
    private let queue = DispatchQueue(label: "texfast.project-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var reported: [URL: Stamp]?
    private var pending: [URL: Stamp]?
    private var pendingSince: Date?

    init(projectURL: URL, rootPDF: URL, onChange: @escaping ([URL]) -> Void) {
        self.projectURL = projectURL
        self.rootPDF = rootPDF
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            reported = snapshot()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func acknowledgeOwnWrite(_ url: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            reported?[url.standardizedFileURL] = stamp(url)
        }
    }

    private func tick() {
        let current = snapshot()
        guard let reported else {
            reported = current
            return
        }
        guard current != reported else {
            pending = nil
            pendingSince = nil
            return
        }
        if current != pending {
            pending = current
            pendingSince = Date()
            return
        }
        guard let pendingSince, Date().timeIntervalSince(pendingSince) >= 0.8 else { return }
        let changed = Set(current.keys).union(reported.keys).filter { current[$0] != reported[$0] }
        self.reported = current
        pending = nil
        self.pendingSince = nil
        if !changed.isEmpty {
            DispatchQueue.main.async { [onChange] in onChange(changed.sorted { $0.path < $1.path }) }
        }
    }

    private func snapshot() -> [URL: Stamp] {
        let extensions: Set<String> = ["tex", "bib", "sty", "cls", "png", "jpg", "jpeg", "heic", "tiff", "svg", "eps", "pdf"]
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: projectURL, includingPropertiesForKeys: [.isDirectoryKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var result: [URL: Stamp] = [:]
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            let url = url.standardizedFileURL
            guard url != rootPDF, extensions.contains(url.pathExtension.lowercased()),
                  let value = stamp(url) else { continue }
            result[url] = value
        }
        return result
    }

    private func stamp(_ url: URL) -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        return Stamp(modified: modified, size: size)
    }

    deinit { stop() }
}
