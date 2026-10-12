import Foundation
import PDFKit
import Darwin

/// One persistent engine cache per main document, exclusively leased until the
/// supervisor exits. Concurrent windows use their own temporary build instead.
final class RealtimeBuildCache {
    let directory: URL
    let persistent: Bool
    private var lockFD: Int32 = -1

    init(root: URL, main: URL) {
        let base = root.appendingPathComponent(".texfast/realtime/\(main.deletingPathExtension().lastPathComponent)", isDirectory: true)
        let shared = base.appendingPathComponent("cache-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let fd = open(shared.appendingPathComponent(".owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        let supervisor = (try? String(contentsOf: shared.appendingPathComponent(".supervisor.pid"), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let stillStopping = supervisor.map { $0 > 1 && (kill($0, 0) == 0 || errno == EPERM) } ?? false
        if fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0 && !stillStopping {
            directory = shared; persistent = true; lockFD = fd
        } else {
            if fd >= 0 { close(fd) }
            directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true); persistent = false
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Restore a sealed complete pass before the engine opens its mutable slots.
    /// A new run may overwrite both slots before it converges or the app closes.
    func prepare(main: URL) {
        guard persistent else { return }
        preserve(main: main)
        let job = main.deletingPathExtension().lastPathComponent
        for slot in 0...1 {
            let pass = directory.appendingPathComponent("bg/pass-\(slot)", isDirectory: true)
            if !valid(pass, job: job) { try? FileManager.default.removeItem(at: pass.appendingPathComponent("rtex-sources")) }
            let saved = directory.appendingPathComponent("startup/pass-\(slot)", isDirectory: true)
            guard valid(saved, job: job) else { continue }
            // copyItem preserves metadata; the marker must remain newer than capture/PDF.
            let temporary = directory.appendingPathComponent("bg/restore-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.copyItem(at: saved, to: temporary)
                try? FileManager.default.removeItem(at: pass)
                try FileManager.default.moveItem(at: temporary, to: pass)
            } catch { try? FileManager.default.removeItem(at: temporary) }
        }
    }

    /// Keep the latest complete source-hashed pass outside the engine's mutable directories.
    func preserve(main: URL) {
        guard persistent else { return }
        let job = main.deletingPathExtension().lastPathComponent
        let candidates = (0...1).map { directory.appendingPathComponent("bg/pass-\($0)", isDirectory: true) }
            .filter { valid($0, job: job) }
        guard let pass = candidates.max(by: {
            modified($0.appendingPathComponent("rtex-sources")) < modified($1.appendingPathComponent("rtex-sources"))
        }) else { return }
        let saved = directory.appendingPathComponent("startup/\(pass.lastPathComponent)", isDirectory: true)
        if valid(saved, job: job),
           (try? Data(contentsOf: saved.appendingPathComponent("rtex-sources"))) == (try? Data(contentsOf: pass.appendingPathComponent("rtex-sources"))),
           modified(saved.appendingPathComponent("rtex-sources")) >= modified(pass.appendingPathComponent("rtex-sources")) { return }
        let parent = saved.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = parent.appendingPathComponent("previous-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: pass, to: temporary)
            guard valid(temporary, job: job) else { try? FileManager.default.removeItem(at: temporary); return }
            if FileManager.default.fileExists(atPath: saved.path) { try FileManager.default.moveItem(at: saved, to: previous) }
            try FileManager.default.moveItem(at: temporary, to: saved)
            try? FileManager.default.removeItem(at: previous)
            // Only one sealed startup pass is needed, with the slot its paths refer to.
            let other = directory.appendingPathComponent("startup/pass-\(pass.lastPathComponent == "pass-0" ? 1 : 0)")
            try? FileManager.default.removeItem(at: other)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if !FileManager.default.fileExists(atPath: saved.path) { try? FileManager.default.moveItem(at: previous, to: saved) }
        }
    }

    private func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    private func valid(_ pass: URL, job: String) -> Bool {
        let marker = pass.appendingPathComponent("rtex-sources")
        let capture = pass.appendingPathComponent("\(job).rtex.json")
        let pdf = pass.appendingPathComponent("\(job).pdf")
        guard let stamp = try? String(contentsOf: marker, encoding: .utf8),
              stamp.trimmingCharacters(in: .whitespacesAndNewlines).count == 16,
              modified(marker) >= max(modified(capture), modified(pdf)),
              let data = try? Data(contentsOf: capture),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = info["pages"] as? Int, pages > 0,
              PDFDocument(url: pdf)?.pageCount == pages else { return false }
        return true
    }

    func release() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        if !persistent { try? FileManager.default.removeItem(at: directory) }
    }
    deinit { release() }
}
