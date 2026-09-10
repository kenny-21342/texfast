import Foundation

/// Polls a file and reports a change once the writer has stopped touching it.
///
/// Polling rather than a `DispatchSource` vnode watch on purpose: most writers —
/// this app included — save atomically by writing a temporary file and renaming
/// it over the original. That replaces the inode, so a vnode watch on the
/// original file descriptor goes deaf after the first save.
///
/// The settle delay matters just as much: `xdvipdfmx` writes a 5 MB PDF
/// progressively, and reloading halfway through yields a truncated document.
/// A change is only reported once size and mtime have held still.
final class FileWatcher {

    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private let url: URL
    private let interval: TimeInterval
    private let settle: TimeInterval
    private let onChange: () -> Void

    private var timer: DispatchSourceTimer?
    private var lastReported: Stamp?
    private var pending: Stamp?
    private var pendingSince: Date?

    init(url: URL, interval: TimeInterval = 0.5, settle: TimeInterval = 0.4,
         onChange: @escaping () -> Void) {
        self.url = url
        self.interval = interval
        self.settle = settle
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        stop()
        lastReported = stamp()          // do not fire for what is already there
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Record the current state as already-seen — call after writing the file
    /// ourselves, so our own save is not reported back as an external change.
    func acknowledgeOwnWrite() {
        lastReported = stamp()
        pending = nil
        pendingSince = nil
    }

    private func tick() {
        let current = stamp()
        guard current != lastReported else {
            pending = nil
            pendingSince = nil
            return
        }
        if current != pending {
            pending = current
            pendingSince = Date()
            return
        }
        guard let since = pendingSince, Date().timeIntervalSince(since) >= settle else { return }
        lastReported = current
        pending = nil
        pendingSince = nil
        onChange()
    }

    private func stamp() -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        return Stamp(modified: modified, size: size)
    }
}
